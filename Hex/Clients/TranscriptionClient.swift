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
import Tokenizers
import WhisperKit

private let transcriptionLogger = HexLog.transcription
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
}

extension TranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = TranscriptionClientLive()
    return Self(
      transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, progressCallback: $3) },
      downloadModel: { try await live.downloadAndLoadModel(variant: $0, progressCallback: $1) },
      deleteModel: { try await live.deleteModel(variant: $0) },
      isModelDownloaded: { await live.isModelDownloaded($0) },
      getAvailableModels: { try await live.getAvailableModels() }
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
  private var isInstallingModel = false
  private var activeTranscriptions = 0

  /// The base folder under which we store model data (e.g., ~/Library/Application Support/...).
  private lazy var modelsBaseFolder: URL = {
    do {
      return try URL.hexModelsDirectory
    } catch {
      fatalError("Could not create Application Support folder: \(error)")
    }
  }()

  // MARK: - Public Methods

  /// Installs (only when explicitly requested by the model UI) and loads a model.
  /// Inference uses `loadInstalledModel` instead and never downloads.
  func downloadAndLoadModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
    guard !isInstallingModel, activeTranscriptions == 0 else {
      throw operationBusyError()
    }
    isInstallingModel = true
    defer { isInstallingModel = false }

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
    case .canaryFluidAudioCoreML, .cohereFluidAudioCoreML, .mediformParakeetCoreML, .omiMedicalParakeetCoreML:
      if currentModelName != variant { await unloadCurrentModel() }
      try await additionalFluidAudio.ensureLoaded(descriptor, progress: progressCallback)
      currentModelName = variant
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
    guard !isInstallingModel, activeTranscriptions == 0 else {
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
    if descriptor.backend == .canaryFluidAudioCoreML || descriptor.backend == .cohereFluidAudioCoreML
      || descriptor.backend == .mediformParakeetCoreML || descriptor.backend == .omiMedicalParakeetCoreML {
      try await additionalFluidAudio.deleteModel(descriptor)
      if currentModelName == variant { currentModelName = nil }
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
    if descriptor.backend == .parakeetFluidAudioCoreML {
      let available = await parakeet.isModelAvailable(modelName)
      parakeetLogger.debug("Parakeet available? \(available)")
      return available
    }
    if descriptor.backend == .qwen3MLX {
      return await qwen.isModelAvailable(descriptor)
    }
    if descriptor.backend == .canaryFluidAudioCoreML || descriptor.backend == .cohereFluidAudioCoreML
      || descriptor.backend == .mediformParakeetCoreML || descriptor.backend == .omiMedicalParakeetCoreML {
      return await additionalFluidAudio.isModelAvailable(descriptor)
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
    guard !isInstallingModel, activeTranscriptions == 0 else {
      throw operationBusyError()
    }
    activeTranscriptions += 1
    defer { activeTranscriptions -= 1 }

    let startAll = Date()
    let model = await resolveVariant(model)
    let descriptor = try LocalASRModelCatalog.descriptor(named: model)

    if descriptor.backend == .parakeetFluidAudioCoreML {
      transcriptionLogger.notice("Transcribing with Parakeet model=\(model) file=\(url.lastPathComponent)")
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
      transcriptionLogger.notice("Transcribing with Qwen3-ASR model=\(model) file=\(url.lastPathComponent)")
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

    if descriptor.backend == .mediformParakeetCoreML || descriptor.backend == .omiMedicalParakeetCoreML {
      transcriptionLogger.notice("Transcribing with \(descriptor.displayName) model=\(model) file=\(url.lastPathComponent)")
      try await additionalFluidAudio.validateLanguage(descriptor, language: options.decoding.language)
      let startLoad = Date()
      try await loadInstalledModel(variant: model, progressCallback: progressCallback)
      transcriptionLogger.info("\(descriptor.displayName) local load took \(String(format: "%.2f", Date().timeIntervalSince(startLoad)))s")
      let startTx = Date()
      let output = try await additionalFluidAudio.transcribe(descriptor, url: url, language: options.decoding.language)
      transcriptionLogger.info("\(descriptor.displayName) transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTx)))s")
      return output
    }

    if descriptor.backend == .canaryFluidAudioCoreML || descriptor.backend == .cohereFluidAudioCoreML {
      try await additionalFluidAudio.validateLanguage(descriptor, language: options.decoding.language)
      transcriptionLogger.notice("Transcribing with \(descriptor.displayName) model=\(model) file=\(url.lastPathComponent)")
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
    transcriptionLogger.notice("Transcribing with WhisperKit model=\(model) file=\(url.lastPathComponent)")
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

    if descriptor.backend == .canaryFluidAudioCoreML || descriptor.backend == .cohereFluidAudioCoreML
      || descriptor.backend == .mediformParakeetCoreML || descriptor.backend == .omiMedicalParakeetCoreML {
      if currentModelName != variant { await unloadCurrentModel() }
      try await additionalFluidAudio.loadInstalled(descriptor, progress: progressCallback)
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
        modelsLogger.notice("Local Whisper tokenizer validation failed; refreshing tokenizer assets during explicit installation: \(error.localizedDescription)")
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

  private func operationBusyError() -> NSError {
    NSError(domain: "TranscriptionClient", code: -6, userInfo: [
      NSLocalizedDescriptionKey: "A model is currently being installed or used. Please try again when that operation finishes.",
    ])
  }

  // Releases both backend objects before another model is loaded.
  private func unloadCurrentModel() async {
    if let whisperKit {
      await whisperKit.unloadModels()
    }
    whisperKit = nil
    currentModelName = nil
    await parakeet.unload()
    await qwen.unload()
    await additionalFluidAudio.unload()
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

      modelsLogger.info("Downloaded model to \(modelFolder.path)")
    } catch {
      // Clean up any partial download if an error occurred
      FileManager.default.removeItemIfExists(at: modelFolder)

      // Rethrow the original error
      modelsLogger.error("Error downloading model \(variant): \(error.localizedDescription)")
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
