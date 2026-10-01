import FluidAudio
import Foundation
import HexCore

private let sessionLogger = HexLog.transcription

/// Result of one finished dictation: the document (source of truth for the
/// dictation box) plus the rendered text for direct insertion.
struct DictationSessionOutput: Equatable, Sendable {
  var document: DictationDocument
  var language: String
  /// Plain text for direct insertion.
  var text: String
  /// Same content with markup (headings, lists, bold/italic) for the dictation box.
  var markdown: String = ""
  /// Unprocessed ASR text (used by the spelling mode).
  var rawText: String = ""
  /// Words the engine was unsure about (confidence < 0.5), for the orange
  /// underline in the dictation box (plan 5.7).
  var uncertainWords: [String] = []
}

/// Turns one captured recording into a `DictationDocument`.
///
/// Quality before latency: the whole recording is decoded once after the stop
/// (Whisper keeps its acoustic context; Turbo 14/14 command words vs. 12/14 on
/// isolated clips) and the words are aligned to the audio pauses measured by
/// `UtteranceSegmenter`. Engines without word timings are decoded utterance by
/// utterance so commands still depend on measured pauses.
struct DictationSessionRunner {
  var transcribeSamples: @Sendable ([Float], String, RequestOptions) async throws -> EngineResult
  var corrector: @Sendable (LexiconContext) async -> LexiconCorrector? = { _ in nil }

  struct Request: Equatable, Sendable {
    var model: String
    var mode: DictationMode
    var commandPauseMs: Int
    var language: String?
    var profile: ASRProfile = .general
    var biasTerms: [String] = []
    var activePacks: [String] = []
    var autoReplacePackTerms = true
    var bypassFormatting = false
    var formatNumbers = true
    var agentFormatting = true
    var englishCommands = true
    var boxOpen = false
  }

  /// Rendered session plus bookkeeping for the hotkey flow.
  func run(_ audioURL: URL, request: Request) async throws -> DictationSessionOutput {
    let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(audioURL)
    return try await run(samples: samples, request: request)
  }

  func run(samples: [Float], request: Request) async throws -> DictationSessionOutput {
    let fallbackLanguage = request.language ?? "de"
    guard !samples.isEmpty else {
      return DictationSessionOutput(document: DictationDocument(), language: fallbackLanguage, text: "")
    }
    let options = RequestOptions(
      language: request.language,
      punctuation: request.mode == .literal && !request.bypassFormatting ? .suppressed : .natural,
      biasTerms: request.biasTerms
    )
    if request.bypassFormatting {
      let result = try await transcribeSamples(samples, request.model, options)
      return DictationSessionOutput(document: DictationDocument(), language: result.detectedLanguage ?? fallbackLanguage, text: result.text, markdown: result.text, rawText: result.text)
    }

    let capabilities = (try? LocalASRModelCatalog.descriptor(named: request.model))?.capabilities
    let utterances = UtteranceSegmenter.segment(samples, config: SegmenterConfig(minPauseMs: request.commandPauseMs))
    let collector = UncertainWordCollector()
    let recording = DictationSessionRunner(
      transcribeSamples: { [transcribeSamples] samples, model, options in
        let result = try await transcribeSamples(samples, model, options)
        await collector.add(result.words)
        return result
      },
      corrector: corrector
    )
    let aligned = try await recording.transcribe(samples, utterances: utterances, wordTimings: capabilities?.wordTimings ?? false, request: request, options: options)

    let language = Self.baseLanguage(request.language ?? aligned.first(where: { $0.language != nil })?.language ?? "de")
    let corrector = await corrector(LexiconContext(
      mode: request.mode,
      language: language,
      profile: request.profile,
      activePacks: request.activePacks,
      autoReplacePackTermsInLiteral: request.autoReplacePackTerms
    ))
    let document = DictationSessionProcessor.makeDocument(
      from: aligned,
      options: DictationSessionOptions(
        mode: request.mode,
        commandPauseMs: request.commandPauseMs,
        englishCommands: request.englishCommands,
        language: language,
        formatNumbers: request.formatNumbers,
        agentFormatting: request.agentFormatting && request.mode == .normal,
        boxOpen: request.boxOpen
      ),
      corrector: corrector
    )
    let text = document.render(AssemblerOptions(language: language, mode: request.mode))
    let markdown = document.render(AssemblerOptions(language: language, mode: request.mode, format: .markdown))
    let rawText = aligned.map(\.text).joined(separator: " ")
    return DictationSessionOutput(
      document: document, language: language, text: text, markdown: markdown, rawText: rawText,
      uncertainWords: await collector.words
    )
  }

  /// "de-DE" / "german" → "de".
  static func baseLanguage(_ language: String) -> String {
    let lower = language.lowercased()
    if lower.hasPrefix("en") || lower == "english" { return "en" }
    if lower.hasPrefix("de") || lower == "german" { return "de" }
    return String(lower.prefix(2))
  }

  fileprivate func transcribe(
    _ samples: [Float],
    utterances: [Utterance],
    wordTimings: Bool,
    request: Request,
    options: RequestOptions
  ) async throws -> [AlignedUtterance] {
    if utterances.isEmpty {
      // No speech above the VAD threshold: still decode once, never drop audio.
      let result = try await transcribeSamples(samples, request.model, options)
      let whole = Utterance(id: 0, range: 0 ..< samples.count, pauseBeforeMs: 0, pauseAfterMs: 0)
      return [AlignedUtterance(utterance: whole, text: result.text, language: result.detectedLanguage)]
    }
    if wordTimings {
      let result = try await transcribeSamples(samples, request.model, options)
      if let aligned = DictationSessionProcessor.align(result, to: utterances) {
        return aligned
      }
      sessionLogger.notice("Word timings unusable; decoding \(utterances.count) utterances sequentially")
    }
    var results: [AlignedUtterance] = []
    results.reserveCapacity(utterances.count)
    for utterance in utterances {
      try Task.checkCancellation()
      let lower = max(0, utterance.range.lowerBound)
      let upper = min(samples.count, utterance.range.upperBound)
      guard lower < upper else { continue }
      let result = try await transcribeSamples(Array(samples[lower ..< upper]), request.model, options)
      results.append(AlignedUtterance(utterance: utterance, text: result.text, language: result.detectedLanguage))
    }
    return results
  }
}

/// Collects low-confidence words from engine results.
actor UncertainWordCollector {
  private(set) var words: [String] = []

  func add(_ engineWords: [EngineWord]) {
    for word in engineWords {
      guard let confidence = word.confidence, confidence < 0.5 else { continue }
      let clean = word.text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
      if clean.count >= 3, !words.contains(clean) { words.append(clean) }
    }
  }
}
