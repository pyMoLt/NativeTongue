import Foundation
import HexCore

/// Transcribes a whole audio file into timed segments (plan 5.11).
///
/// VAD utterances (≤ 25 s) are grouped into ~4-minute blocks cut at pauses.
/// Engines with word timings decode a whole block (keeps acoustic context) and
/// the words are aligned back to the utterances; other engines decode each
/// utterance. Progress = processed audio seconds / total.
struct FileTranscriptionRunner {
  var transcribeSamples: @Sendable ([Float], String, RequestOptions) async throws -> EngineResult
  var corrector: @Sendable (LexiconContext) async -> LexiconCorrector? = { _ in nil }

  struct Request: Equatable, Sendable {
    var model: String
    var mode: DictationMode
    var language: String?
    var profile: ASRProfile = .general
    var activePacks: [String] = []
    var autoReplacePackTerms = true
    var biasTerms: [String] = []
    var formatNumbers = true
    var englishCommands = true
  }

  func run(
    samples: [Float],
    request: Request,
    progress: @Sendable (Double) async -> Void = { _ in }
  ) async throws -> [TranscriptSegment] {
    let sampleRate = 16_000
    guard !samples.isEmpty else { return [] }
    let utterances = UtteranceSegmenter.segment(samples, config: SegmenterConfig())
    guard !utterances.isEmpty else { return [] }
    let options = RequestOptions(
      language: request.language,
      punctuation: request.mode == .literal ? .suppressed : .natural,
      biasTerms: request.biasTerms
    )
    let wordTimings = (try? LocalASRModelCatalog.descriptor(named: request.model))?.capabilities.wordTimings ?? false
    let total = Double(samples.count)

    var aligned: [AlignedUtterance] = []
    for block in FileBlockPlanner.blocks(utterances, sampleRate: sampleRate) {
      try Task.checkCancellation()
      let lower = block.first!.range.lowerBound, upper = min(block.last!.range.upperBound, samples.count)
      var blockResult: [AlignedUtterance]?
      if wordTimings, lower < upper {
        let result = try await transcribeSamples(Array(samples[lower ..< upper]), request.model, options)
        // Utterance ranges relative to the block, so word times line up.
        let relative = block.map { utterance in
          Utterance(
            id: utterance.id,
            range: (utterance.range.lowerBound - lower) ..< (utterance.range.upperBound - lower),
            pauseBeforeMs: utterance.pauseBeforeMs,
            pauseAfterMs: utterance.pauseAfterMs
          )
        }
        blockResult = DictationSessionProcessor.align(result, to: relative, sampleRate: sampleRate).map { items in
          zip(items, block).map { item, original in
            AlignedUtterance(utterance: original, text: item.text, language: item.language)
          }
        }
      }
      if blockResult == nil {
        var sequential: [AlignedUtterance] = []
        for utterance in block {
          try Task.checkCancellation()
          let from = max(0, utterance.range.lowerBound), to = min(samples.count, utterance.range.upperBound)
          guard from < to else { continue }
          let result = try await transcribeSamples(Array(samples[from ..< to]), request.model, options)
          sequential.append(AlignedUtterance(utterance: utterance, text: result.text, language: result.detectedLanguage))
          await progress(Double(to) / total)
        }
        blockResult = sequential
      }
      aligned += blockResult ?? []
      await progress(Double(upper) / total)
    }

    let language = DictationSessionRunner.baseLanguage(request.language ?? aligned.first(where: { $0.language != nil })?.language ?? "de")
    let corrector = await corrector(LexiconContext(
      mode: request.mode,
      language: language,
      profile: request.profile,
      activePacks: request.activePacks,
      autoReplacePackTermsInLiteral: request.autoReplacePackTerms
    ))
    return Self.segments(from: aligned, request: request, language: language, corrector: corrector, sampleRate: sampleRate)
  }

  /// Each utterance becomes one segment. Structural/edit/box commands make no
  /// sense in a finished recording and are dropped; punctuation, numbers and
  /// lexicon corrections apply as in dictation.
  static func segments(
    from aligned: [AlignedUtterance],
    request: Request,
    language: String,
    corrector: LexiconCorrector?,
    sampleRate: Int
  ) -> [TranscriptSegment] {
    let context = ClassifierContext(mode: request.mode, englishCommands: request.englishCommands)
    let options = DictationTextPipeline.Options(
      mode: request.mode,
      language: language,
      englishCommands: request.englishCommands,
      formatNumbers: request.formatNumbers,
      agentFormatting: false
    )
    var segments: [TranscriptSegment] = []
    for item in aligned {
      let durationMs = item.utterance.range.count * 1_000 / sampleRate
      guard !HallucinationFilter.shouldDrop(text: item.text, utteranceDurationMs: durationMs) else { continue }
      let classification = UtteranceClassifier.classify(
        text: item.text,
        pauseBeforeMs: item.utterance.pauseBeforeMs,
        pauseAfterMs: item.utterance.pauseAfterMs,
        context: context
      )
      guard case let .dictation(_, text, _) = classification else { continue }
      var tokens = DictationTextPipeline.process(text, options: options)
      if let corrector { tokens = corrector.correct(tokens).tokens }
      let rendered = Assembler.render(tokens, options: AssemblerOptions(language: language, mode: request.mode))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !rendered.isEmpty else { continue }
      segments.append(TranscriptSegment(
        id: segments.count,
        start: Double(item.utterance.range.lowerBound) / Double(sampleRate),
        end: Double(item.utterance.range.upperBound) / Double(sampleRate),
        text: rendered
      ))
    }
    return segments
  }
}
