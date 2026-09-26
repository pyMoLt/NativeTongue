import FluidAudio
import Foundation
import HexCore

private let sessionLogger = HexLog.transcription

/// Result of one finished dictation: the document (source of truth for the
/// dictation box) plus the rendered text for direct insertion.
struct DictationSessionOutput: Equatable {
  var document: DictationDocument
  var language: String
  var text: String
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

  struct Request: Equatable {
    var model: String
    var mode: DictationMode
    var commandPauseMs: Int
    var language: String?
    var biasTerms: [String] = []
    var bypassFormatting = false
    var formatNumbers = true
    var agentFormatting = true
    var englishCommands = true
    var boxOpen = false
  }

  static func biasTerms(fromVocabulary vocabulary: String) -> [String] {
    Array(vocabulary
      .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;")))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .prefix(50))
  }

  /// Convenience used by the hotkey flow: file in, rendered text out.
  func run(
    _ audioURL: URL,
    model: String,
    mode: DictationMode,
    commandPauseMs: Int,
    language: String?,
    activeVocabulary: String,
    bypassFormatting: Bool
  ) async throws -> String {
    let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(audioURL)
    let request = Request(
      model: model,
      mode: mode,
      commandPauseMs: commandPauseMs,
      language: language,
      biasTerms: Self.biasTerms(fromVocabulary: activeVocabulary),
      bypassFormatting: bypassFormatting,
      agentFormatting: mode == .normal
    )
    return try await run(samples: samples, request: request).text
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
      return DictationSessionOutput(document: DictationDocument(), language: result.detectedLanguage ?? fallbackLanguage, text: result.text)
    }

    let capabilities = (try? LocalASRModelCatalog.descriptor(named: request.model))?.capabilities
    let utterances = UtteranceSegmenter.segment(samples, config: SegmenterConfig(minPauseMs: request.commandPauseMs))
    let aligned = try await transcribe(samples, utterances: utterances, wordTimings: capabilities?.wordTimings ?? false, request: request, options: options)

    let language = request.language ?? aligned.first(where: { $0.language != nil })?.language ?? "de"
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
      )
    )
    let text = document.render(AssemblerOptions(language: language, mode: request.mode))
    return DictationSessionOutput(document: document, language: language, text: text)
  }

  private func transcribe(
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
