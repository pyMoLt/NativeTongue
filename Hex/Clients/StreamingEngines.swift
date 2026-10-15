import AVFoundation
import FluidAudio
import Foundation
import HexCore
import Hub
import MLX
import Speech
import VoxtralRealtime

private let streamingLogger = HexLog.streaming

/// Text produced by a streaming engine since the previous call.
struct StreamingUpdate: Equatable, Sendable {
  /// Final text; never revised afterwards.
  var committed = ""
  /// Volatile tail, display only.
  var pending = ""
  /// `committed` starts a new block (emulated / Apple results) and needs
  /// spacing and capitalisation fitted to the text before it.
  var startsSegment = false

  mutating func merge(_ other: StreamingUpdate) {
    if committed.isEmpty { startsSegment = other.startsSegment }
    committed += other.committed
    pending = other.pending
  }
}

/// A speech engine that turns live 16 kHz audio into text while you speak.
protocol StreamingEngine: Actor {
  func begin(language: String?) async throws
  func feed(_ samples: [Float]) async throws -> StreamingUpdate
  func end() async throws -> StreamingUpdate
  func unload() async
}

// MARK: - Nemotron 3.5 (native, Core ML)

/// NVIDIA Nemotron 3.5 ASR Streaming Multilingual via FluidAudio. Cache-aware
/// RNN-T: emitted text is only ever appended, so it can be typed immediately.
actor NemotronStreamingEngine: StreamingEngine {
  static let modelName = StreamingSettings.recommendedModel

  private var manager: StreamingNemotronMultilingualAsrManager?
  private var loadedDirectory: URL?
  private var emitted = AppendOnlyDelta()

  static func variantDirectory(chunkMs: Int) -> URL {
    URL.applicationSupportDirectory
      .appendingPathComponent("FluidAudio/Models", isDirectory: true)
      .appendingPathComponent("nemotron-multilingual", isDirectory: true) // FluidAudio Repo.nemotronMultilingual.folderName
      .appendingPathComponent("latin/\(chunkMs)ms", isDirectory: true)
  }

  static func isInstalled(chunkMs: Int) -> Bool {
    FileManager.default.fileExists(atPath: variantDirectory(chunkMs: chunkMs).appendingPathComponent("metadata.json").path)
  }

  /// Explicit install action: downloads the Latin-script (DE/EN/…) variant.
  static func install(chunkMs: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
    // The app keeps FluidAudio offline; only this explicit install may fetch.
    _ = try await ModelHubNetwork.whileInstalling {
      try await StreamingNemotronMultilingualAsrManager.downloadVariant(languageCode: "de-DE", chunkMs: chunkMs) { update in
        progress(update.fractionCompleted)
      }
    }
  }

  static func delete() throws {
    let root = variantDirectory(chunkMs: 1120).deletingLastPathComponent().deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
  }

  func load(chunkMs: Int) async throws {
    let directory = Self.variantDirectory(chunkMs: chunkMs)
    guard Self.isInstalled(chunkMs: chunkMs) else {
      throw NSError(domain: "Streaming", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nemotron \(chunkMs) ms is not installed. Install it under Models or Streaming."])
    }
    if manager != nil, loadedDirectory == directory { return }
    await unload()
    let manager = StreamingNemotronMultilingualAsrManager()
    try await manager.loadModels(from: directory)
    self.manager = manager
    loadedDirectory = directory
  }

  func begin(language: String?) async throws {
    guard let manager else { throw NSError(domain: "Streaming", code: 2, userInfo: [NSLocalizedDescriptionKey: "Streaming model not loaded."]) }
    await manager.reset()
    await manager.setLanguage(Self.languageCode(language))
    emitted.reset()
  }

  func feed(_ samples: [Float]) async throws -> StreamingUpdate {
    guard let manager else { return StreamingUpdate() }
    _ = try await manager.process(samples: samples)
    return delta(await manager.getPartialTranscript())
  }

  func end() async throws -> StreamingUpdate {
    guard let manager else { return StreamingUpdate() }
    let final = try await manager.finish()
    return delta(final)
  }

  func unload() async {
    if let manager { await manager.cleanup() }
    manager = nil
    loadedDirectory = nil
  }

  /// New text since the last call. The final pass may capitalise the first
  /// letter, so the prefix check ignores case.
  private func delta(_ running: String) -> StreamingUpdate {
    let (new, revised) = emitted.next(running)
    if revised { streamingLogger.notice("Nemotron revised earlier text; only new characters are typed") }
    return new.isEmpty ? StreamingUpdate() : StreamingUpdate(committed: new)
  }

  static func languageCode(_ language: String?) -> String? {
    guard let language, !language.isEmpty else { return nil }
    if language.hasPrefix("de") { return "de-DE" }
    if language.hasPrefix("en") { return "en-US" }
    return language
  }
}

// MARK: - Voxtral Mini 4B Realtime (native, MLX)

/// Mistral Voxtral Mini 4B Realtime (vendored mlx-audio-swift streaming session).
actor VoxtralStreamingEngine: StreamingEngine {
  static let modelName = "voxtral-mini-4b-realtime-4bit-mlx"
  static let repository = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
  static let revision = "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e"

  private var model: VoxtralRealtimeModel?
  private var session: VoxtralRealtimeStreamSession?

  static var baseDirectory: URL {
    ((try? URL.hexModelsDirectory) ?? URL.hexModelsDirectoryPath).appendingPathComponent("voxtral", isDirectory: true)
  }

  static var modelDirectory: URL {
    repository.split(separator: "/").reduce(baseDirectory.appendingPathComponent("models", isDirectory: true)) {
      $0.appendingPathComponent(String($1), isDirectory: true)
    }
  }

  static func isInstalled() -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: modelDirectory.path)) ?? []
    return files.contains("config.json") && files.contains("tekken.json") && files.contains { $0.hasSuffix(".safetensors") }
  }

  static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
    let hub = HubApi(downloadBase: baseDirectory, useOfflineMode: false)
    _ = try await hub.snapshot(
      from: Hub.Repo(id: repository),
      revision: revision,
      matching: ["config.json", "tekken.json", "*.safetensors", "model.safetensors.index.json"]
    ) { value in progress(value.fractionCompleted) }
  }

  static func delete() throws {
    if FileManager.default.fileExists(atPath: baseDirectory.path) { try FileManager.default.removeItem(at: baseDirectory) }
  }

  func load() async throws {
    guard model == nil else { return }
    guard Self.isInstalled() else {
      throw NSError(domain: "Streaming", code: 1, userInfo: [NSLocalizedDescriptionKey: "Voxtral is not installed. Install it under Models."])
    }
    model = try VoxtralRealtimeModel.fromDirectory(Self.modelDirectory)
  }

  func begin(language: String?) async throws {
    guard let model else { throw NSError(domain: "Streaming", code: 2, userInfo: [NSLocalizedDescriptionKey: "Streaming model not loaded."]) }
    session = model.makeStreamSession(temperature: 0, transcriptionDelayMs: delayMs)
  }

  private var steps = 0
  /// Transcription delay of the next session (Settings → Streaming).
  private var delayMs = 480

  func setDelay(milliseconds: Int) {
    // The model counts the delay in 80 ms audio tokens (trained for 80–2400 ms).
    delayMs = min(2_400, max(80, milliseconds / 80 * 80))
  }

  func feed(_ samples: [Float]) async throws -> StreamingUpdate {
    guard let session else { return StreamingUpdate() }
    let text = session.step(samples).text
    steps += 1
    // Keep MLX's buffer cache small during long sessions.
    if steps % 50 == 0 { MLXMemoryPolicy.clearCache() }
    return StreamingUpdate(committed: text)
  }

  func end() async throws -> StreamingUpdate {
    guard let session else { return StreamingUpdate() }
    let delta = session.finish()
    self.session = nil
    return StreamingUpdate(committed: delta.text)
  }

  func unload() async {
    session = nil
    model = nil
    MLX.Memory.clearCache()
  }
}

/// MLX keeps freed GPU buffers in a cache that by default may grow to the
/// whole memory limit (measured: 30+ GB while streaming Voxtral). The app caps
/// it and clears it after work (V2.5 memory fix).
enum MLXMemoryPolicy {
  static let cacheLimitBytes = 512 * 1_024 * 1_024

  static func apply() {
    MLX.Memory.cacheLimit = cacheLimitBytes
  }

  static func clearCache() {
    MLX.Memory.clearCache()
  }
}

/// MLX memory figures for diagnostics and tests.
enum MLXMemoryInfo {
  static func summary() -> String {
    String(format: "MLX active %.0f MB, cache %.0f MB, peak %.0f MB",
      Double(MLX.Memory.activeMemory) / 1e6, Double(MLX.Memory.cacheMemory) / 1e6, Double(MLX.Memory.peakMemory) / 1e6)
  }

  static var peakMegabytes: Double { Double(MLX.Memory.peakMemory) / 1e6 }
  static func resetPeak() { MLX.Memory.peakMemory = 0 }
}

// MARK: - Apple SpeechAnalyzer (native, system)

/// Apple's on-device DictationTranscriber with volatile results: only final
/// results are typed, the volatile tail is shown as pending text.
actor AppleStreamingEngine: StreamingEngine {
  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var analyzer: SpeechAnalyzer?
  private var collector: Task<Void, Never>?
  private var format: AVAudioFormat?
  private var buffered = StreamingUpdate()

  func begin(language: String?) async throws {
    let module = DictationTranscriber(
      locale: AppleSpeechASRClient.locale(for: language),
      contentHints: [],
      transcriptionOptions: [.punctuation],
      reportingOptions: [.volatileResults],
      attributeOptions: []
    )
    guard await AssetInventory.status(forModules: [module]) == .installed else {
      throw NSError(domain: "Streaming", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple speech assets are not installed. Install them under Models."])
    }
    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
      ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let analyzer = SpeechAnalyzer(modules: [module])
    try await analyzer.prepareToAnalyze(in: format)
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    self.format = format
    self.analyzer = analyzer
    self.continuation = continuation
    buffered = StreamingUpdate()
    collector = Task { [weak self] in
      do {
        for try await result in module.results {
          let text = String(result.text.characters)
          await self?.receive(text: text, isFinal: result.isFinal)
        }
      } catch {
        streamingLogger.error("Apple streaming results ended: \(error.localizedDescription, privacy: .private)")
      }
    }
    try await analyzer.start(inputSequence: stream)
  }

  private func receive(text: String, isFinal: Bool) {
    if isFinal {
      let piece = text.trimmingCharacters(in: .whitespaces)
      guard !piece.isEmpty else { return }
      buffered.merge(StreamingUpdate(committed: piece, pending: "", startsSegment: true))
    } else {
      buffered.pending = text
    }
  }

  func feed(_ samples: [Float]) async throws -> StreamingUpdate {
    if let format, let continuation, !samples.isEmpty {
      continuation.yield(AnalyzerInput(buffer: try AppleSpeechASRClient.buffer(from: samples, format: format)))
    }
    defer { buffered = StreamingUpdate(pending: buffered.pending) }
    return buffered
  }

  func end() async throws -> StreamingUpdate {
    continuation?.finish()
    try await analyzer?.finalizeAndFinishThroughEndOfInput()
    await collector?.value
    defer { buffered = StreamingUpdate() }
    var result = buffered
    result.pending = ""
    return result
  }

  func unload() async {
    continuation?.finish()
    collector?.cancel()
    analyzer = nil
    continuation = nil
  }
}

// MARK: - Emulated (any batch model)

/// Batch models (Whisper, Parakeet, …): each pause-delimited block is
/// transcribed and typed as a whole.
actor EmulatedStreamingEngine: StreamingEngine {
  private var detector: StreamingPauseDetector
  private let transcribe: @Sendable ([Float]) async throws -> String

  init(pauseMs: Int, maxBlockSeconds: Int, transcribe: @escaping @Sendable ([Float]) async throws -> String) {
    detector = StreamingPauseDetector(pauseMs: pauseMs, maxBlockSeconds: maxBlockSeconds)
    self.transcribe = transcribe
  }

  func begin(language: String?) async throws {}

  func feed(_ samples: [Float]) async throws -> StreamingUpdate {
    var update = StreamingUpdate()
    for block in detector.append(samples) {
      update.merge(try await transcribeBlock(block))
    }
    return update
  }

  func end() async throws -> StreamingUpdate {
    guard let rest = detector.flush() else { return StreamingUpdate() }
    return try await transcribeBlock(rest)
  }

  func unload() async {}

  private func transcribeBlock(_ block: [Float]) async throws -> StreamingUpdate {
    let text = try await transcribe(block).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return StreamingUpdate() }
    return StreamingUpdate(committed: text + " ", startsSegment: true)
  }
}
