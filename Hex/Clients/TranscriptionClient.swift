//
//  TranscriptionClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Hub
import Sharing
import Tokenizers
import AudioCommon
import WhisperKit

private let transcriptionLogger = HexLog.transcription

extension Notification.Name {
  /// The speech model was unloaded after the idle time.
  static let speechModelIdleUnloaded = Notification.Name("NativeTongue.speechModelIdleUnloaded")
}
private let modelsLogger = HexLog.models
private let parakeetLogger = HexLog.parakeet

struct TranscriptionOutput: Sendable {
  let text: String
  let wordTimings: [TranscriptWordTiming]
}

struct ASRTranscriptionOptions: Sendable {
  var decoding: DecodingOptions
  var terminologyContext: String?
}

/// A client that downloads and loads WhisperKit models, then transcribes audio files using the loaded model.
/// Exposes progress callbacks to report overall download-and-load percentage and transcription progress.
@DependencyClient
struct TranscriptionClient {
  /// Transcribes an audio file at the specified `URL` using the named `model`.
  /// Reports transcription progress via `progressCallback`.
  var transcribe: @Sendable (URL, String, ASRTranscriptionOptions, @escaping (Progress) -> Void) async throws -> TranscriptionOutput

  /// Ensures a model is downloaded (if missing) and loaded into memory, reporting progress via `progressCallback`.
  var downloadModel: @Sendable (String, @escaping (Progress) -> Void) async throws -> Void

  /// Deletes a model from disk if it exists
  var deleteModel: @Sendable (String) async throws -> Void

  /// Checks if a named model is already downloaded on this system.
  var isModelDownloaded: @Sendable (String) async -> Bool = { _ in false }

  /// Lists model variants from the app-bundled catalog. This must not access the network.
  var getAvailableModels: @Sendable () async throws -> [String]

  /// V2: transcribes one pause-segmented utterance (16 kHz mono) with the
  /// model-specific options (punctuation policy, language, optional biasing).
  var transcribeSamples: @Sendable ([Float], String, RequestOptions) async throws -> EngineResult

  /// Loads an installed model ahead of use (hotkey press). Never downloads.
  var prewarm: @Sendable (String) async throws -> Void

  /// Unloads whatever model is resident (idle timeout, memory pressure).
  var unloadModel: @Sendable () async -> Void

  /// Name of the resident model, if any.
  var loadedModel: @Sendable () async -> String? = { nil }

  /// Configures automatic unloading after 0, 2, 5, 10, or 30 idle minutes.
  var configureIdleUnload: @Sendable (Int) async -> Void = { _ in }

  /// Current process footprint. Core ML/ANE allocations may not all be included.
  var processFootprintBytes: @Sendable () async -> UInt64? = { nil }
}

extension TranscriptionClient: DependencyKey {
  /// Keep the XCTest app host side-effect free. Engine integration tests opt in
  /// to `liveValue` explicitly, while feature tests override only what they use.
  static var testValue: Self {
    Self(
      transcribe: { _, _, _, _ in throw NSError(domain: "TranscriptionClient.testValue", code: 1) },
      downloadModel: { _, _ in throw NSError(domain: "TranscriptionClient.testValue", code: 1) },
      deleteModel: { _ in throw NSError(domain: "TranscriptionClient.testValue", code: 1) },
      isModelDownloaded: { _ in false },
      getAvailableModels: { [] },
      transcribeSamples: { _, _, _ in throw NSError(domain: "TranscriptionClient.testValue", code: 1) },
      prewarm: { _ in throw NSError(domain: "TranscriptionClient.testValue", code: 1) },
      unloadModel: {},
      loadedModel: { nil },
      configureIdleUnload: { _ in },
      processFootprintBytes: { nil }
    )
  }

  static var liveValue: Self {
    let live = TranscriptionClientLive()
    return Self(
      transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, progressCallback: $3) },
      downloadModel: { try await live.downloadAndLoadModel(variant: $0, progressCallback: $1) },
      deleteModel: { try await live.deleteModel(variant: $0) },
      isModelDownloaded: { await live.isModelDownloaded($0) },
      getAvailableModels: { try await live.getAvailableModels() },
      transcribeSamples: { try await live.transcribe(samples: $0, model: $1, options: $2) },
      prewarm: { try await live.prewarm(model: $0) },
      unloadModel: { await live.unloadModel() },
      loadedModel: { await live.loadedModelName() },
      configureIdleUnload: { await live.configureIdleUnload(minutes: $0) },
      processFootprintBytes: { await live.processFootprintBytes() }
    )
  }
}

extension DependencyValues {
  var transcription: TranscriptionClient {
    get { self[TranscriptionClient.self] }
    set { self[TranscriptionClient.self] = newValue }
  }
}

actor TranscriptionClientLive {
  // MARK: - Stored Properties

  /// The current in-memory `WhisperKit` instance, if any.
  private var whisperKit: WhisperKit?

  /// The name of the currently loaded model, if any.
  private var currentModelName: String?
  private var parakeet: ParakeetClient = ParakeetClient()
  private var qwen: QwenASRClient = QwenASRClient()
  private var additionalFluidAudio = AdditionalFluidAudioASRClient()
  private var cohere = CohereMLXASRClient()
  private var appleSpeech = AppleSpeechASRClient()
  /// Punctuation-only token IDs per Whisper model (literal-mode decoder mask).
  private var whisperPunctuationTokens: [String: [Int]] = [:]
  private var isInstallingModel = false
  private var activeTranscriptions = 0
  private var prewarmTask: Task<Void, Error>?
  private var idleUnloadMinutes = 10
  private var idleUnloadTask: Task<Void, Never>?
  private var idleUnloadGeneration: UInt64 = 0
  private let idleUnloadDelayForTesting: Duration?

  init(idleUnloadDelayForTesting: Duration? = nil) {
    self.idleUnloadDelayForTesting = idleUnloadDelayForTesting
  }

  /// The base folder under which we store model data (e.g., ~/Library/Application Support/...).
  private lazy var modelsBaseFolder: URL = {
    do {
      return try URL.hexModelsDirectory
    } catch {
      // Do not crash the app: model installs and loads on this path fail with a
      // reportable error instead (audit A12).
      transcriptionLogger.error("Could not create the models folder: \(error.localizedDescription, privacy: .private)")
      return URL.hexModelsDirectoryPath
    }
  }()

  // MARK: - Public Methods

  /// Installs (only when explicitly requested by the model UI) and loads a model.
  /// Inference uses `loadInstalledModel` instead and never downloads.
  func downloadAndLoadModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
    guard !isInstallingModel, activeTranscriptions == 0, prewarmTask == nil else {
      throw operationBusyError()
    }
    isInstallingModel = true
    cancelIdleUnload()
    defer {
      isInstallingModel = false
      scheduleIdleUnload()
    }

    // Resolve wildcard patterns (e.g., "distil*large-v3") to a concrete variant
    let variant = await resolveVariant(variant)
    // Special handling for corrupted or malformed variant names
    if variant.isEmpty {
      throw NSError(
        domain: "TranscriptionClient",
        code: -3,
        userInfo: [
          NSLocalizedDescriptionKey: "Cannot download model: Empty model name",
        ]
      )
    }

    let descriptor = try LocalASRModelCatalog.descriptor(named: variant)
    switch descriptor.backend {
    case .parakeetFluidAudioCoreML:
      if currentModelName != variant { await unloadCurrentModel() }
      try await parakeet.ensureLoaded(modelName: variant, progress: progressCallback)
      currentModelName = variant
      return
    case .qwen3MLX:
      if currentModelName != variant { await unloadCurrentModel() }
      try await qwen.ensureLoaded(descriptor, progress: progressCallback)
      currentModelName = variant
      return
    case .canaryFluidAudioCoreML, .omiMedicalParakeetCoreML:
      if currentModelName != variant { await unloadCurrentModel() }
      try await additionalFluidAudio.ensureLoaded(descriptor, progress: progressCallback)
      currentModelName = variant
      return
    case .cohereMLX:
      if currentModelName != variant { await unloadCurrentModel() }
      try await cohere.install(progress: progressCallback)
      try await cohere.load()
      currentModelName = variant
      return
    case .appleSpeechAnalyzer:
      if currentModelName != variant { await unloadCurrentModel() }
      try await appleSpeech.install(progress: progressCallback)
      currentModelName = variant
      return
    case .nemotronStreamingCoreML:
      @Shared(.hexSettings) var hexSettings: HexSettings
      try await NemotronStreamingEngine.install(chunkMs: hexSettings.streaming.nemotronChunkMs) { fraction in
        progressCallback(Self.progress(fraction))
      }
      return
    case .voxtralRealtimeMLX:
      try await VoxtralStreamingEngine.install { fraction in progressCallback(Self.progress(fraction)) }
      return
    case .whisperKitCoreML:
      break
    }

    if currentModelName == variant, whisperKit != nil {
      let completed = Progress(totalUnitCount: 100)
      completed.completedUnitCount = 100
      progressCallback(completed)
      return
    }

    if currentModelName != variant { await unloadCurrentModel() }

    let overallProgress = Progress(totalUnitCount: 100)
    overallProgress.completedUnitCount = 0
    progressCallback(overallProgress)

    modelsLogger.info("Preparing model download and load for \(variant)")

    // 1) Core ML model download phase (0-50% progress)
    if !containsCoreMLModelFiles(in: modelPath(for: variant)) {
      try await downloadModelIfNeeded(variant: variant) { downloadProgress in
        let fraction = downloadProgress.fractionCompleted * 0.5
        overallProgress.completedUnitCount = Int64(fraction * 100)
        progressCallback(overallProgress)
      }
    } else {
      // Skip download phase if already downloaded
      overallProgress.completedUnitCount = 50
      progressCallback(overallProgress)
    }

    // 2) Whisper tokenizer download/validation phase (50-60% progress).
    try await ensureWhisperTokenizerInstalled(variant: variant) { tokenizerProgress in
      overallProgress.completedUnitCount = 50 + Int64(tokenizerProgress.fractionCompleted * 10)
      progressCallback(overallProgress)
    }

    // 3) Model loading phase (60-100% progress)
    try await loadWhisperKitModel(variant) { loadingProgress in
      let fraction = 0.6 + (loadingProgress.fractionCompleted * 0.4)
      overallProgress.completedUnitCount = Int64(fraction * 100)
      progressCallback(overallProgress)
    }

    // Final progress update
    overallProgress.completedUnitCount = 100
    progressCallback(overallProgress)
  }

  /// Deletes a model from disk if it exists
  func deleteModel(variant: String) async throws {
    guard !isInstallingModel, activeTranscriptions == 0, prewarmTask == nil else {
      throw operationBusyError()
    }
    let descriptor = try LocalASRModelCatalog.descriptor(named: variant)
    if descriptor.backend == .parakeetFluidAudioCoreML {
      try await parakeet.deleteCaches(modelName: variant)
      if currentModelName == variant { await unloadCurrentModel() }
      return
    }
    if descriptor.backend == .qwen3MLX {
      try await qwen.deleteModel(descriptor)
      if currentModelName == variant { currentModelName = nil }
      return
    }
    if descriptor.backend == .canaryFluidAudioCoreML || descriptor.backend == .omiMedicalParakeetCoreML {
      try await additionalFluidAudio.deleteModel(descriptor)
      if currentModelName == variant { currentModelName = nil }
      return
    }
    if descriptor.backend == .cohereMLX {
      try await cohere.delete()
      if currentModelName == variant { currentModelName = nil }
      return
    }
    if descriptor.backend == .appleSpeechAnalyzer {
      // System-managed assets; nothing app-owned to delete.
      if currentModelName == variant { currentModelName = nil }
      return
    }
    if descriptor.backend == .nemotronStreamingCoreML || descriptor.backend == .voxtralRealtimeMLX {
      await StreamingEngineHost.shared.unloadAll()
      if descriptor.backend == .nemotronStreamingCoreML { try NemotronStreamingEngine.delete() } else { try VoxtralStreamingEngine.delete() }
      return
    }
    let modelFolder = modelPath(for: variant)

    // Check if the model exists
    guard FileManager.default.fileExists(atPath: modelFolder.path) else {
      // Model doesn't exist, nothing to delete
      return
    }

    // If this is the currently loaded model, unload it first
    if currentModelName == variant {
      await unloadCurrentModel()
    }

    // Delete the model directory
    try FileManager.default.removeItem(at: modelFolder)

    modelsLogger.info("Deleted model \(variant)")
  }

  /// Returns `true` if the model is already downloaded to the local folder.
  /// Performs a thorough check to ensure the model files are actually present and usable.
  func isModelDownloaded(_ modelName: String) async -> Bool {
    guard let descriptor = try? LocalASRModelCatalog.descriptor(named: modelName) else { return false }
    if descriptor.backend == .nemotronStreamingCoreML {
      @Shared(.hexSettings) var hexSettings: HexSettings
      return NemotronStreamingEngine.isInstalled(chunkMs: hexSettings.streaming.nemotronChunkMs)
    }
    if descriptor.backend == .voxtralRealtimeMLX {
      return VoxtralStreamingEngine.isInstalled()
    }
    if descriptor.backend == .parakeetFluidAudioCoreML {
      let available = await parakeet.isModelAvailable(modelName)
      parakeetLogger.debug("Parakeet available? \(available)")
      return available
    }
    if descriptor.backend == .qwen3MLX {
      return await qwen.isModelAvailable(descriptor)
    }
    if descriptor.backend == .canaryFluidAudioCoreML || descriptor.backend == .omiMedicalParakeetCoreML {
      return await additionalFluidAudio.isModelAvailable(descriptor)
    }
    if descriptor.backend == .cohereMLX {
      return await cohere.isInstalled()
    }
    if descriptor.backend == .appleSpeechAnalyzer {
      return await appleSpeech.isInstalled()
    }
    let modelFolderPath = modelPath(for: modelName).path
    let fileManager = FileManager.default

    // First, check if the basic model directory exists
    guard fileManager.fileExists(atPath: modelFolderPath) else {
      // Don't print logs that would spam the console
      return false
    }

    let modelFolder = URL(fileURLWithPath: modelFolderPath, isDirectory: true)
    return containsCoreMLModelFiles(in: modelFolder) && whisperTokenizerFolderCandidates(for: modelName)
      .contains(where: containsRequiredWhisperTokenizerFiles(in:))
  }

  /// Lists only the bundled curated options. No model-hub request is made here.
  func getAvailableModels() async throws -> [String] {
    let entries = try LocalASRModelCatalog.load()
    var seen = Set<String>()
    return entries.map(\.internalName).filter { seen.insert($0).inserted }
  }

  /// Transcribes the audio file at `url` using a `model` name.
  /// Loads an already-installed model locally if needed. Never downloads or queries a model hub.
  func transcribe(
    url: URL,
    model: String,
    options: ASRTranscriptionOptions,
    progressCallback: @escaping (Progress) -> Void
  ) async throws -> TranscriptionOutput {
    if let prewarmTask { try await prewarmTask.value }
    let model = await resolveVariant(model)
    let descriptor = try LocalASRModelCatalog.descriptor(named: model)
    if descriptor.backend == .cohereMLX || descriptor.backend == .appleSpeechAnalyzer {
      let samples = try AudioFileLoader.load(url: url, targetSampleRate: 16_000)
      let result = try await transcribe(
        samples: samples,
        model: model,
        options: RequestOptions(language: options.decoding.language, punctuation: .natural)
      )
      return TranscriptionOutput(
        text: result.text,
        wordTimings: result.words.map { TranscriptWordTiming(word: $0.text, startTime: $0.start, endTime: $0.end) }
      )
    }

    guard !isInstallingModel, activeTranscriptions == 0 else {
      throw operationBusyError()
    }
    activeTranscriptions += 1
    cancelIdleUnload()
    defer {
      activeTranscriptions -= 1
      scheduleIdleUnload()
    }

    let startAll = Date()
    if descriptor.backend == .parakeetFluidAudioCoreML {
      transcriptionLogger.notice("Transcribing with Parakeet model=\(model)")
      let startLoad = Date()
      try await loadInstalledModel(variant: model, progressCallback: progressCallback)
      transcriptionLogger.info("Parakeet ensureLoaded took \(String(format: "%.2f", Date().timeIntervalSince(startLoad)))s")
      let preparedClip = try ParakeetClipPreparer.ensureMinimumDuration(url: url, logger: parakeetLogger)
      defer { preparedClip.cleanup() }
      let startTx = Date()
      let output = try await parakeet.transcribe(preparedClip.url)
      transcriptionLogger.info("Parakeet transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTx)))s")
      transcriptionLogger.info("Parakeet request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")
      return output
    }

    if descriptor.backend == .qwen3MLX {
      transcriptionLogger.notice("Transcribing with Qwen3-ASR model=\(model)")
      let startLoad = Date()
      try await loadInstalledModel(variant: model, progressCallback: progressCallback)
      transcriptionLogger.info("Qwen3-ASR ensureLoaded took \(String(format: "%.2f", Date().timeIntervalSince(startLoad)))s")
      let startTx = Date()
      let output = try await qwen.transcribe(
        url,
        language: options.decoding.language,
        context: options.terminologyContext
      )
      transcriptionLogger.info("Qwen3-ASR transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTx)))s")
      transcriptionLogger.info("Qwen3-ASR request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")
      return output
    }

    if descriptor.backend == .omiMedicalParakeetCoreML {
      transcriptionLogger.notice("Transcribing with \(descriptor.displayName) model=\(model)")
      try await additionalFluidAudio.validateLanguage(descriptor, language: options.decoding.language)
      let startLoad = Date()
      try await loadInstalledModel(variant: model, progressCallback: progressCallback)
      transcriptionLogger.info("\(descriptor.displayName) local load took \(String(format: "%.2f", Date().timeIntervalSince(startLoad)))s")
      let startTx = Date()
      let output = try await additionalFluidAudio.transcribe(descriptor, url: url, language: options.decoding.language)
      transcriptionLogger.info("\(descriptor.displayName) transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTx)))s")
      return output
    }

    if descriptor.backend == .canaryFluidAudioCoreML {
      try await additionalFluidAudio.validateLanguage(descriptor, language: options.decoding.language)
      transcriptionLogger.notice("Transcribing with \(descriptor.displayName) model=\(model)")
      let startLoad = Date()
      try await loadInstalledModel(variant: model, progressCallback: progressCallback)
      transcriptionLogger.info("\(descriptor.displayName) local load took \(String(format: "%.2f", Date().timeIntervalSince(startLoad)))s")
      let startTx = Date()
      let output = try await additionalFluidAudio.transcribe(
        descriptor,
        url: url,
        language: options.decoding.language
      )
      transcriptionLogger.info("\(descriptor.displayName) transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTx)))s")
      transcriptionLogger.info("\(descriptor.displayName) request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")
      return output
    }

    // Load or switch to the required model if needed.
    if whisperKit == nil || model != currentModelName {
      let startLoad = Date()
      try await loadInstalledModel(variant: model, progressCallback: progressCallback)
      let loadDuration = Date().timeIntervalSince(startLoad)
      transcriptionLogger.info("WhisperKit ensureLoaded model=\(model) took \(String(format: "%.2f", loadDuration))s")
    }

    guard let whisperKit = whisperKit else {
      throw NSError(
        domain: "TranscriptionClient",
        code: -1,
        userInfo: [
          NSLocalizedDescriptionKey: "Failed to initialize WhisperKit for model: \(model)",
        ]
      )
    }

    // Perform the transcription.
    transcriptionLogger.notice("Transcribing with WhisperKit model=\(model)")
    let startTx = Date()
    var decodeOptions = options.decoding
    if let terminologyContext = options.terminologyContext,
       !terminologyContext.isEmpty,
       let tokenizer = whisperKit.tokenizer {
      decodeOptions.promptTokens = tokenizer.encode(text: terminologyContext)
    }
    let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: decodeOptions)
    transcriptionLogger.info("WhisperKit transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTx)))s")
    transcriptionLogger.info("WhisperKit request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")

    // Concatenate results from all segments.
    let text = results.map(\.text).joined(separator: " ")
    let wordTimings = results
      .flatMap(\.segments)
      .flatMap { $0.words ?? [] }
      .map { TranscriptWordTiming(word: $0.word, startTime: Double($0.start), endTime: Double($0.end)) }
      .sorted { $0.startTime < $1.startTime }
    return TranscriptionOutput(text: text, wordTimings: wordTimings)
  }

  // MARK: - V2 samples API

  func prewarm(model: String) async throws {
    let model = await resolveVariant(model)
    guard !model.isEmpty else { return }
    if let prewarmTask { try await prewarmTask.value }
    guard !isInstallingModel, activeTranscriptions == 0 else { throw operationBusyError() }
    cancelIdleUnload()
    let task = Task { [self] in
      defer {
        prewarmTask = nil
        scheduleIdleUnload()
      }
      try await loadInstalledModel(variant: model) { _ in }
    }
    prewarmTask = task
    try await task.value
  }

  func unloadModel() async {
    guard !isInstallingModel, activeTranscriptions == 0, prewarmTask == nil else { return }
    await unloadCurrentModel()
  }

  func loadedModelName() -> String? { currentModelName }

  func configureIdleUnload(minutes: Int) {
    idleUnloadMinutes = [0, 2, 5, 10, 30].contains(minutes) ? minutes : 10
    scheduleIdleUnload()
  }

  func processFootprintBytes() -> UInt64? { ProcessMemoryMeter.currentFootprintBytes() }

  func transcribe(samples: [Float], model: String, options: RequestOptions) async throws -> EngineResult {
    if let prewarmTask { try await prewarmTask.value }
    guard !isInstallingModel, activeTranscriptions == 0 else { throw operationBusyError() }
    activeTranscriptions += 1
    cancelIdleUnload()
    defer {
      activeTranscriptions -= 1
      scheduleIdleUnload()
    }

    let model = await resolveVariant(model)
    let descriptor = try LocalASRModelCatalog.descriptor(named: model)
    try await loadInstalledModel(variant: model) { _ in }

    let result: EngineResult
    switch descriptor.backend {
    case .parakeetFluidAudioCoreML:
      result = try await parakeet.transcribe(samples: samples, language: options.language)
    case .qwen3MLX:
      result = try await qwen.transcribe(samples: samples, options: options)
    case .canaryFluidAudioCoreML, .omiMedicalParakeetCoreML:
      result = try await additionalFluidAudio.transcribe(descriptor, samples: samples, options: options)
    case .cohereMLX:
      result = try await cohere.transcribe(samples: samples, options: options)
    case .appleSpeechAnalyzer:
      result = try await appleSpeech.transcribe(samples: samples, options: options)
    case .nemotronStreamingCoreML, .voxtralRealtimeMLX:
      throw Self.streamingOnlyError(descriptor)
    case .whisperKitCoreML:
      result = try await transcribeWhisper(samples: samples, model: model, options: options)
    }
    return EngineResultNormalizer.apply(result, punctuation: options.punctuation)
  }

  private func transcribeWhisper(samples: [Float], model: String, options: RequestOptions) async throws -> EngineResult {
    guard let whisperKit else {
      throw NSError(domain: "TranscriptionClient", code: -1, userInfo: [
        NSLocalizedDescriptionKey: "Failed to initialize WhisperKit for model: \(model)",
      ])
    }
    guard !samples.isEmpty else { return EngineResult(text: "") }
    var decode = DecodingOptions(
      language: options.language,
      temperatureFallbackCount: WhisperDecodingPolicy.temperatureFallbackCount,
      detectLanguage: options.language == nil,
      wordTimestamps: true,
      chunkingStrategy: samples.count > 29 * 16_000 ? .vad : ChunkingStrategy.none
    )
    if options.punctuation == .suppressed, let tokenizer = whisperKit.tokenizer {
      if whisperPunctuationTokens[model] == nil {
        let punctuation = CharacterSet(charactersIn: ".,;:!?")
        var ids: [Int] = []
        for id in 0..<tokenizer.specialTokens.specialTokenBegin {
          let piece = tokenizer.decode(tokens: [id]).trimmingCharacters(in: .whitespaces)
          if !piece.isEmpty, piece.unicodeScalars.allSatisfy({ punctuation.contains($0) }) { ids.append(id) }
        }
        whisperPunctuationTokens[model] = ids
      }
      decode.supressTokens += whisperPunctuationTokens[model] ?? []
    }
    func run(_ options: DecodingOptions) async throws -> EngineResult {
      let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
      let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
      let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
        EngineWord(text: $0.word, start: Double($0.start), end: Double($0.end), confidence: $0.probability)
      }
      return EngineResult(
        text: text,
        words: words,
        detectedLanguage: results.first?.language,
        punctuationWasSuppressed: options.supressTokens.isEmpty == false
      )
    }
    let terms = Array(options.biasTerms.prefix(30))
    if !terms.isEmpty, let tokenizer = whisperKit.tokenizer {
      // Experimental: Whisper prompts can drop whole passages (benchmark 2026-09-26).
      var prompted = decode
      prompted.promptTokens = tokenizer.encode(text: " " + terms.joined(separator: ", "))
      let result = try await run(prompted)
      if BiasLeakGuard.leakedRange(in: result.text, biasTerms: terms) == nil { return result }
      transcriptionLogger.notice("Whisper prompt leak detected; re-decoding without prompt")
    }
    return try await run(decode)
  }

  // MARK: - Private Helpers

  /// Resolve legacy wildcard selections against the bundled catalog only.
  private func resolveVariant(_ variant: String) async -> String {
    guard variant.contains("*") || variant.contains("?") else { return variant }

    let names: [String]
    do { names = try await getAvailableModels() } catch { return variant }

    // Build tuple array with download status for matching models
    var models: [(name: String, isDownloaded: Bool)] = []
    for name in names where ModelPatternMatcher.matches(variant, name) {
      models.append((name, await isModelDownloaded(name)))
    }

    return ModelPatternMatcher.resolvePattern(variant, from: models) ?? variant
  }

  /// Loads an already-installed backend without going through either backend's downloader.
  private func loadInstalledModel(
    variant: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    guard await isModelDownloaded(variant) else {
      throw NSError(domain: "TranscriptionClient", code: -4, userInfo: [
        NSLocalizedDescriptionKey: "This model is not installed. Choose Download in Model Settings before dictating.",
      ])
    }

    let descriptor = try LocalASRModelCatalog.descriptor(named: variant)
    if descriptor.streamingOnly {
      throw Self.streamingOnlyError(descriptor)
    }
    if descriptor.backend == .parakeetFluidAudioCoreML {
      if currentModelName != variant { await unloadCurrentModel() }
      try await parakeet.loadInstalled(modelName: variant, progress: progressCallback)
      currentModelName = variant
      return
    }

    if descriptor.backend == .qwen3MLX {
      if currentModelName != variant { await unloadCurrentModel() }
      try await qwen.loadInstalled(descriptor, progress: progressCallback)
      currentModelName = variant
      return
    }

    if descriptor.backend == .canaryFluidAudioCoreML || descriptor.backend == .omiMedicalParakeetCoreML {
      if currentModelName != variant { await unloadCurrentModel() }
      try await additionalFluidAudio.loadInstalled(descriptor, progress: progressCallback)
      currentModelName = variant
      return
    }

    if descriptor.backend == .cohereMLX {
      if currentModelName != variant { await unloadCurrentModel() }
      try await cohere.load()
      currentModelName = variant
      return
    }

    if descriptor.backend == .appleSpeechAnalyzer {
      if currentModelName != variant { await unloadCurrentModel() }
      currentModelName = variant
      return
    }

    if currentModelName != variant || whisperKit == nil {
      await unloadCurrentModel()
      try await loadWhisperKitModel(variant) { progress in
        progressCallback(progress)
      }
    }
  }

  /// Creates or returns the local folder (on disk) for a given `variant` model.
  private func modelPath(for variant: String) -> URL {
    // Remove any possible path traversal or invalid characters from variant name
    let sanitizedVariant = variant.components(separatedBy: CharacterSet(charactersIn: "./\\")).joined(separator: "_")

    return modelsBaseFolder
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent(sanitizedVariant, isDirectory: true)
  }

  /// Creates or returns the local folder for the tokenizer files of a given `variant`.
  private func tokenizerPath(for variant: String) -> URL {
    modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
  }

  /// Mirrors WhisperKit 0.15.0's tokenizer search order: the Hub-style folder under
  /// tokenizerFolder first, then tokenizerFolder itself. The first matching folder wins.
  private func whisperTokenizerFolderCandidates(for variant: String) -> [URL] {
    let tokenizerRoot = tokenizerPath(for: variant)
    let repository = whisperTokenizerRepository(for: variant)
    let hubFolder = repository.split(separator: "/").reduce(
      tokenizerRoot.appendingPathComponent("models", isDirectory: true)
    ) { folder, component in
      folder.appendingPathComponent(String(component), isDirectory: true)
    }
    return [hubFolder, tokenizerRoot]
  }

  private func whisperTokenizerRepository(for variant: String) -> String {
    if variant.contains("tiny.en") { return "openai/whisper-tiny.en" }
    if variant.contains("tiny") { return "openai/whisper-tiny" }
    if variant.contains("base.en") { return "openai/whisper-base.en" }
    if variant.contains("base") { return "openai/whisper-base" }
    return "openai/whisper-large-v3"
  }

  private func containsCoreMLModelFiles(in folder: URL) -> Bool {
    ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
      containsCoreMLModel(named: $0, in: folder)
    }
  }

  private func containsCoreMLModel(named name: String, in folder: URL) -> Bool {
    let fileManager = FileManager.default
    let compiledModel = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
    let packagedModel = folder
      .appendingPathComponent("\(name).mlpackage", isDirectory: true)
      .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
    return fileManager.fileExists(atPath: compiledModel.path) || fileManager.fileExists(atPath: packagedModel.path)
  }

  private func containsRequiredWhisperTokenizerFiles(in folder: URL) -> Bool {
    let fileManager = FileManager.default
    return fileManager.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path)
      && fileManager.fileExists(atPath: folder.appendingPathComponent("tokenizer_config.json").path)
  }

  /// Downloads tokenizer assets only as part of the user's explicit model-install action.
  /// Inference calls this validation path only and never invokes the Hub downloader.
  private func ensureWhisperTokenizerInstalled(
    variant: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    if let tokenizerFolder = whisperTokenizerFolderCandidates(for: variant)
      .first(where: containsRequiredWhisperTokenizerFiles(in:)) {
      do {
        try await validateWhisperTokenizer(in: tokenizerFolder)
        let completed = Progress(totalUnitCount: 100)
        completed.completedUnitCount = 100
        progressCallback(completed)
        return
      } catch {
        modelsLogger.notice("Local Whisper tokenizer validation failed; refreshing tokenizer assets during explicit installation: \(error.localizedDescription, privacy: .private)")
      }
    }

    let tokenizerRoot = tokenizerPath(for: variant)
    if FileManager.default.fileExists(atPath: tokenizerRoot.path) {
      try FileManager.default.removeItem(at: tokenizerRoot)
    }
    try FileManager.default.createDirectory(at: tokenizerRoot, withIntermediateDirectories: true)

    let hub = HubApi(downloadBase: tokenizerRoot, useOfflineMode: false)
    let repository = whisperTokenizerRepository(for: variant)
    _ = try await hub.snapshot(
      from: HubApi.Repo(id: repository),
      matching: ["tokenizer.json", "tokenizer_config.json"]
    ) { progress in
      progressCallback(progress)
    }

    guard let tokenizerFolder = whisperTokenizerFolderCandidates(for: variant)
      .first(where: containsRequiredWhisperTokenizerFiles(in:)) else {
      throw NSError(domain: "TranscriptionClient", code: -7, userInfo: [
        NSLocalizedDescriptionKey: "The Whisper tokenizer download did not include tokenizer.json and tokenizer_config.json.",
      ])
    }
    try await validateWhisperTokenizer(in: tokenizerFolder)
  }

  /// Parses the exact local folder WhisperKit will select and checks critical Whisper tokens.
  /// This guard runs before WhisperKit, whose own loader otherwise falls back to the Hub
  /// when local parsing fails.
  private func validateWhisperTokenizer(in folder: URL) async throws {
    let offlineHub = HubApi(downloadBase: folder.deletingLastPathComponent(), useOfflineMode: true)
    let tokenizer = try await AutoTokenizer.from(modelFolder: folder, hubApi: offlineHub, strict: true)
    let requiredTokens = [
      "<|endoftext|>", "<|startoftranscript|>", "<|transcribe|>", "<|notimestamps|>", "<|de|>", "<|en|>",
    ]
    let missingTokens = requiredTokens.filter { tokenizer.convertTokenToId($0) == nil }
    guard missingTokens.isEmpty else {
      throw NSError(domain: "TranscriptionClient", code: -8, userInfo: [
        NSLocalizedDescriptionKey: "The local Whisper tokenizer is missing required special tokens: \(missingTokens.joined(separator: ", ")).",
      ])
    }
  }

  static func progress(_ fraction: Double) -> Progress {
    let progress = Progress(totalUnitCount: 100)
    progress.completedUnitCount = Int64(max(0, min(1, fraction)) * 100)
    return progress
  }

  static func streamingOnlyError(_ descriptor: LocalASRModelDescriptor) -> NSError {
    NSError(domain: "TranscriptionClient", code: -7, userInfo: [
      NSLocalizedDescriptionKey: "\(descriptor.displayName) works in Streaming mode only. Choose another model for Normal or Literal.",
    ])
  }

  private func operationBusyError() -> NSError {
    NSError(domain: "TranscriptionClient", code: -6, userInfo: [
      NSLocalizedDescriptionKey: "A model is currently being installed or used. Please try again when that operation finishes.",
    ])
  }

  // Releases both backend objects before another model is loaded.
  private func unloadCurrentModel() async {
    cancelIdleUnload()
    if let whisperKit {
      await whisperKit.unloadModels()
    }
    whisperKit = nil
    currentModelName = nil
    await parakeet.unload()
    await qwen.unload()
    await additionalFluidAudio.unload()
    await cohere.unload()
    await StreamingEngineHost.shared.unloadAll()
  }

  private func cancelIdleUnload() {
    // A canceled timer may already have resumed and queued an actor call.
    // Invalidate that call as well, not only the sleeping task.
    idleUnloadGeneration &+= 1
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
  }

  private func scheduleIdleUnload() {
    cancelIdleUnload()
    guard let modelName = currentModelName,
          idleUnloadMinutes > 0,
          !isInstallingModel,
          prewarmTask == nil,
          activeTranscriptions == 0 else { return }
    let minutes = idleUnloadMinutes
    let generation = idleUnloadGeneration
    let delay = idleUnloadDelayForTesting ?? .seconds(minutes * 60)
    idleUnloadTask = Task { [weak self] in
      do { try await Task.sleep(for: delay) }
      catch { return }
      await self?.unloadIfStillIdle(modelName: modelName, generation: generation)
    }
  }

  private func unloadIfStillIdle(modelName: String, generation: UInt64) async {
    guard generation == idleUnloadGeneration,
          currentModelName == modelName,
          !isInstallingModel,
          prewarmTask == nil,
          activeTranscriptions == 0 else { return }
    // Avoid canceling the timer task while it awaits the model unload.
    idleUnloadTask = nil
    await unloadCurrentModel()
    modelsLogger.info("Unloaded idle ASR model")
    // Free the vocabulary index too; the next hotkey press rebuilds it (audit A13).
    NotificationCenter.default.post(name: .speechModelIdleUnloaded, object: nil)
  }

  /// Downloads the model to a temporary folder (if it isn't already on disk),
  /// then moves it into its final folder in `modelsBaseFolder`.
  private func downloadModelIfNeeded(
    variant: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let modelFolder = modelPath(for: variant)

    // Keep tokenizer assets independent: a missing tokenizer must not discard valid weights.
    let hasModelFiles = containsCoreMLModelFiles(in: modelFolder)
    if FileManager.default.fileExists(atPath: modelFolder.path), !hasModelFiles {
      try FileManager.default.removeItem(at: modelFolder)
    }

    // If all Core ML model components are already present, only the tokenizer phase remains.
    if hasModelFiles {
      return
    }

    modelsLogger.info("Downloading model \(variant)")

    // Create parent directories
    let parentDir = modelFolder.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

    do {
      // Download directly using the exact variant name provided
      // WhisperKit 0.15.0 changed downloader params: passing
      // "argmaxinc/whisperkit-coreml" to a parameter interpreted as a host
      // yields NSURLErrorCannotFindHost in production builds that need
      // to fetch models for the first time. Let WhisperKit use its
      // default repo/host (Hugging Face) by omitting the repo/host arg.
      let tempFolder = try await WhisperKit.download(
        variant: variant,
        downloadBase: nil,
        useBackgroundSession: false,
        progressCallback: { progress in
          progressCallback(progress)
        }
      )

      // Ensure target folder exists
      try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)

      // Move the downloaded snapshot to the final location
      try moveContents(of: tempFolder, to: modelFolder)

      modelsLogger.info("Downloaded model assets")
    } catch {
      // Clean up any partial download if an error occurred
      FileManager.default.removeItemIfExists(at: modelFolder)

      // Rethrow the original error
      modelsLogger.error("Error downloading model \(variant): \(error.localizedDescription, privacy: .private)")
      throw error
    }
  }

  /// Loads a local model folder via `WhisperKitConfig`, optionally reporting load progress.
  private func loadWhisperKitModel(
    _ modelName: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let loadingProgress = Progress(totalUnitCount: 100)
    loadingProgress.completedUnitCount = 0
    progressCallback(loadingProgress)

    let modelFolder = modelPath(for: modelName)
    let tokenizerFolder = tokenizerPath(for: modelName)

    guard let selectedTokenizerFolder = whisperTokenizerFolderCandidates(for: modelName)
      .first(where: containsRequiredWhisperTokenizerFiles(in:)) else {
      throw NSError(domain: "TranscriptionClient", code: -9, userInfo: [
        NSLocalizedDescriptionKey: "The local Whisper tokenizer is incomplete. Reinstall the model while online, then dictate again.",
      ])
    }
    do {
      try await validateWhisperTokenizer(in: selectedTokenizerFolder)
    } catch {
      throw NSError(domain: "TranscriptionClient", code: -10, userInfo: [
        NSLocalizedDescriptionKey: "The local Whisper tokenizer could not be validated, so transcription was stopped before WhisperKit could try a Hub fallback. Reinstall this model while online. Details: \(error.localizedDescription)",
      ])
    }

    // Use WhisperKit's config to load the model
    let config = WhisperKitConfig(
      model: modelName,
      modelFolder: modelFolder.path,
      tokenizerFolder: tokenizerFolder,
      // verbose: true,
      // logLevel: .debug,
      prewarm: false,
      load: true,
      download: false
    )

    // The initializer automatically calls `loadModels`.
    whisperKit = try await WhisperKit(config)
    currentModelName = modelName

    // Finalize load progress
    loadingProgress.completedUnitCount = 100
    progressCallback(loadingProgress)

    modelsLogger.info("Loaded WhisperKit model \(modelName)")
  }

  /// Moves all items from `sourceFolder` into `destFolder` (shallow move of directory contents).
  private func moveContents(of sourceFolder: URL, to destFolder: URL) throws {
    let fileManager = FileManager.default
    let items = try fileManager.contentsOfDirectory(atPath: sourceFolder.path)
    for item in items {
      let src = sourceFolder.appendingPathComponent(item)
      let dst = destFolder.appendingPathComponent(item)
      try fileManager.moveItem(at: src, to: dst)
    }
  }
}

/// Whisper decoding policy. WhisperKit's default (5 fallbacks) re-samples failed
/// segments at rising temperatures with random top-k sampling, so the same audio
/// gave a different transcript on every run. Measured 2026-09-26 on the
/// terminology recording (Turbo, 3 runs each): fallback 5 → 3 different texts,
/// fallback 0 → identical texts, same term score (32/47 natural, 31/47 literal)
/// and WER. Greedy decoding is therefore the default.
enum WhisperDecodingPolicy {
  nonisolated(unsafe) static var temperatureFallbackCount = 0
}
