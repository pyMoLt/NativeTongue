import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let streamingLogger = HexLog.streaming

/// What the streaming session reports to the UI.
enum StreamingEvent: Equatable, Sendable {
  /// Recognised but not yet typed (unfinished word, volatile tail).
  case pending(String)
  /// Speech stopped for the configured time; the feature ends the session.
  case silenceTimeout
  /// All text typed, microphone released.
  case finished
  case failed(String)
}

/// Parameters for one streaming session.
struct StreamingRequest: Sendable {
  var settings: HexSettings
  /// Lowercased alias → correct spelling (user vocabulary).
  var aliases: [String: String] = [:]
  /// Where finished text goes. Default: typed at the cursor of the frontmost app.
  var sink: (@MainActor @Sendable (String) -> Void)?
}

@DependencyClient
struct StreamingClient {
  var start: @Sendable (_ request: StreamingRequest, _ onEvent: @escaping @Sendable (StreamingEvent) -> Void) async throws -> Void
  /// Ends the session: the remaining text is still typed.
  var stop: @Sendable () async -> Void = {}
  /// Ends the session and drops text that was not typed yet.
  var cancel: @Sendable () async -> Void = {}
}

extension StreamingClient: DependencyKey {
  static var liveValue: Self {
    let controller = StreamingSessionController()
    return Self(
      start: { try await controller.start($0, onEvent: $1) },
      stop: { await controller.stop() },
      cancel: { await controller.cancel() }
    )
  }

  static var testValue: Self {
    Self(start: { _, _ in }, stop: {}, cancel: {})
  }
}

extension DependencyValues {
  var streaming: StreamingClient {
    get { self[StreamingClient.self] }
    set { self[StreamingClient.self] = newValue }
  }
}

// MARK: - Engine host

/// Owns the loaded streaming engines. Only one speech model is resident:
/// the batch engines are unloaded before a native streaming engine loads, and
/// `TranscriptionClient` unloads these when it loads a batch model.
actor StreamingEngineHost {
  static let shared = StreamingEngineHost()

  private var nemotron: NemotronStreamingEngine?
  private var voxtral: VoxtralStreamingEngine?
  private var apple: AppleStreamingEngine?
  private var idleTask: Task<Void, Never>?
  private var activeSessions = 0
  private var idleGeneration: UInt64 = 0

  func sessionStarted() {
    activeSessions += 1
    idleGeneration &+= 1
    idleTask?.cancel()
    idleTask = nil
  }

  func sessionFinished(idleMinutes: Int) {
    activeSessions = max(0, activeSessions - 1)
    guard activeSessions == 0, idleMinutes > 0 else { return }
    idleGeneration &+= 1
    let generation = idleGeneration
    idleTask = Task {
      do { try await Task.sleep(for: .seconds(idleMinutes * 60)) }
      catch { return }
      await unloadIfIdle(generation: generation)
    }
  }

  private func unloadIfIdle(generation: UInt64) async {
    guard generation == idleGeneration, activeSessions == 0 else { return }
    await unloadAll()
    NotificationCenter.default.post(name: .speechModelIdleUnloaded, object: nil)
  }

  func unloadAll() async {
    idleGeneration &+= 1
    idleTask?.cancel()
    idleTask = nil
    await nemotron?.unload()
    await voxtral?.unload()
    await apple?.unload()
    nemotron = nil
    voxtral = nil
    apple = nil
  }

  func nemotronEngine(chunkMs: Int) async throws -> NemotronStreamingEngine {
    let engine = nemotron ?? NemotronStreamingEngine()
    await voxtral?.unload()
    voxtral = nil
    try await engine.load(chunkMs: chunkMs)
    nemotron = engine
    return engine
  }

  func voxtralEngine() async throws -> VoxtralStreamingEngine {
    let engine = voxtral ?? VoxtralStreamingEngine()
    await nemotron?.unload()
    nemotron = nil
    try await engine.load()
    voxtral = engine
    return engine
  }

  func appleEngine() -> AppleStreamingEngine {
    let engine = apple ?? AppleStreamingEngine()
    apple = engine
    return engine
  }
}

// MARK: - Session

/// Runs streaming sessions: microphone → engine → text processor → cursor.
/// A new session may start while the previous one still types its rest;
/// its text is typed afterwards (sessions are stacked in order).
actor StreamingSessionController {
  @Dependency(\.recording) private var recording
  @Dependency(\.transcription) private var transcription

  private var session: Session?
  private var lastSessionDone: Task<Void, Never>?

  private final class Session: @unchecked Sendable {
    var isCancelled = false
    var processing: Task<Void, Never>?
  }

  func start(_ request: StreamingRequest, onEvent: @escaping @Sendable (StreamingEvent) -> Void) async throws {
    await StreamingEngineHost.shared.sessionStarted()
    let settings = request.settings
    let engine: any StreamingEngine
    do {
      let descriptor = try LocalASRModelCatalog.descriptor(named: settings.model(for: .streaming))
      engine = try await makeEngine(descriptor, settings: settings)
      try await engine.begin(language: settings.outputLanguage)
    } catch {
      await StreamingEngineHost.shared.sessionFinished(idleMinutes: settings.idleUnloadMinutes)
      throw error
    }
    let language = settings.outputLanguage

    await recording.startStreamingRecording()
    let audio = await recording.liveAudio()
    let session = Session()
    self.session = session
    let previous = lastSessionDone
    let queue = SampleQueue()
    let frontmostApp = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    // Read the bounded live stream promptly; the engine may be slower than realtime.
    let reader = Task.detached {
      for await chunk in audio { await queue.push(chunk.samples) }
      await queue.close()
    }

    let processing = Task.detached { [transcription] in
      var processor = StreamingTextProcessor(options: .init(
        settings: settings.streaming,
        language: language,
        englishCommands: settings.englishCommandsEnabled,
        aliases: request.aliases
      ))
      let typist = Typist(
        method: settings.streaming.insertionMethod,
        adapt: settings.streaming.adaptSpacingAndCase,
        appSwitch: settings.streaming.appSwitchBehavior,
        targetApp: frontmostApp,
        sink: request.sink
      )
      var silence = SilenceTracker(limitSeconds: settings.streaming.autoStopSilenceSeconds)
      let started = Date()
      var audioSamples = 0
      // Earlier sessions finish typing first.
      await previous?.value
      do {
        while let samples = await queue.next() {
          if session.isCancelled { break }
          audioSamples += samples.count
          let update = try await engine.feed(samples)
          await self.deliver(update, processor: &processor, typist: typist, session: session, onEvent: onEvent)
          if silence.add(samples) { onEvent(.silenceTimeout) }
          // During a speech pause the engine adds nothing new to the last
          // word: type it now instead of waiting for the next word.
          if silence.isPausing, let rest = processor.releaseHeldWord(), !session.isCancelled {
            _ = await typist.type(rest, startsSegment: false)
            onEvent(.pending(""))
          }
        }
        _ = transcription
        if !session.isCancelled {
          let last = try await engine.end()
          await self.deliver(last, processor: &processor, typist: typist, session: session, onEvent: onEvent)
          let rest = processor.flush()
          if !rest.isEmpty { _ = await typist.type(rest, startsSegment: false) }
        }
        onEvent(.pending(""))
        onEvent(.finished)
        let audioSeconds = Double(audioSamples) / 16_000
        let elapsed = Date().timeIntervalSince(started)
        streamingLogger.notice("Streaming session ended: audio \(audioSeconds, format: .fixed(precision: 1)) s, processed in \(elapsed, format: .fixed(precision: 1)) s")
      } catch {
        streamingLogger.error("Streaming failed: \(error.localizedDescription, privacy: .private)")
        onEvent(.failed(error.localizedDescription))
      }
      reader.cancel()
      MLXMemoryPolicy.clearCache()
      await StreamingEngineHost.shared.sessionFinished(idleMinutes: settings.idleUnloadMinutes)
    }
    session.processing = processing
    lastSessionDone = processing
  }

  private func deliver(
    _ update: StreamingUpdate,
    processor: inout StreamingTextProcessor,
    typist: Typist,
    session: Session,
    onEvent: @Sendable (StreamingEvent) -> Void
  ) async {
    guard !session.isCancelled else { return }
    if update.startsSegment {
      let rest = processor.flush()
      if !rest.isEmpty { _ = await typist.type(rest, startsSegment: false) }
    }
    let ready = processor.push(update.committed)
    if !ready.isEmpty {
      let typed = await typist.type(ready, startsSegment: update.startsSegment)
      if !typed { session.isCancelled = true; onEvent(.silenceTimeout) }
    }
    onEvent(.pending((processor.heldBack + update.pending).trimmingCharacters(in: .whitespaces)))
  }

  func stop() async {
    guard session != nil else { return }
    session = nil
    let result = await recording.stopRecording()
    if case let .captured(url) = result { FileManager.default.removeItemIfExists(at: url) }
  }

  func cancel() async {
    guard let session else { return }
    session.isCancelled = true
    self.session = nil
    let result = await recording.stopRecording()
    if case let .captured(url) = result { FileManager.default.removeItemIfExists(at: url) }
  }

  private func makeEngine(_ descriptor: LocalASRModelDescriptor, settings: HexSettings) async throws -> any StreamingEngine {
    switch descriptor.backend {
    case .nemotronStreamingCoreML:
      await transcription.unloadModel()
      return try await StreamingEngineHost.shared.nemotronEngine(chunkMs: settings.streaming.nemotronChunkMs)
    case .voxtralRealtimeMLX:
      await transcription.unloadModel()
      return try await StreamingEngineHost.shared.voxtralEngine()
    case .appleSpeechAnalyzer:
      return await StreamingEngineHost.shared.appleEngine()
    default:
      await StreamingEngineHost.shared.unloadAll()
      let model = descriptor.internalName
      let language = settings.outputLanguage
      let keepPunctuation = settings.streaming.punctuationMode != .literal
      return EmulatedStreamingEngine(
        pauseMs: settings.streaming.emulatedPauseMs,
        maxBlockSeconds: settings.streaming.emulatedMaxBlockSeconds
      ) { [transcription] samples in
        let options = RequestOptions(language: language, punctuation: keepPunctuation ? .natural : .suppressed)
        return try await transcription.transcribeSamples(samples, model, options).text
      }
    }
  }
}

/// Unbounded hand-off between the microphone reader and the engine.
private actor SampleQueue {
  private var chunks: [[Float]] = []
  private var closed = false
  private var waiter: CheckedContinuation<[Float]?, Never>?

  func push(_ samples: [Float]) {
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: samples)
    } else {
      chunks.append(samples)
    }
  }

  func close() {
    closed = true
    waiter?.resume(returning: nil)
    waiter = nil
  }

  /// Next chunk (batched), or nil after `close()` once drained.
  func next() async -> [Float]? {
    if !chunks.isEmpty {
      let batch = chunks.flatMap { $0 }
      chunks.removeAll()
      return batch
    }
    if closed { return nil }
    return await withCheckedContinuation { waiter = $0 }
  }
}

/// Seconds without speech, for the auto-stop setting.
private struct SilenceTracker {
  let limitSeconds: Int
  private var quietSamples = 0
  private var fired = false

  init(limitSeconds: Int) { self.limitSeconds = limitSeconds }

  /// Speech paused for at least 0.6 s.
  var isPausing: Bool { quietSamples >= 9_600 }

  /// True once when the silence limit is reached.
  mutating func add(_ samples: [Float]) -> Bool {
    guard !samples.isEmpty else { return false }
    let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    if rms >= 0.012 { quietSamples = 0; fired = false } else { quietSamples += samples.count }
    if limitSeconds > 0, !fired, quietSamples >= limitSeconds * 16_000 { fired = true; return true }
    return false
  }
}

/// Types text at the cursor and keeps it consistent with what the user typed.
private actor Typist {
  let method: StreamingInsertionMethod
  let adapt: Bool
  let appSwitch: StreamingAppSwitchBehavior
  let targetApp: String?
  let sink: (@MainActor @Sendable (String) -> Void)?
  private var typedTail = ""
  private var typedAnything = false
  private var heldWhileAway = ""

  init(method: StreamingInsertionMethod, adapt: Bool, appSwitch: StreamingAppSwitchBehavior, targetApp: String?, sink: (@MainActor @Sendable (String) -> Void)?) {
    self.method = method
    self.adapt = adapt
    self.appSwitch = appSwitch
    self.targetApp = targetApp
    self.sink = sink
  }

  /// Returns false when the session must stop (user switched apps, setting "stop").
  func type(_ piece: String, startsSegment: Bool) async -> Bool {
    if let sink {
      await MainActor.run { sink(piece) }
      return true
    }
    let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    if let targetApp, frontmost != targetApp {
      switch appSwitch {
      case .pause:
        heldWhileAway += piece
        return true
      case .stop:
        return false
      case .continueInNewApp:
        break
      }
    }
    let text = heldWhileAway + piece
    heldWhileAway = ""
    let before = await MainActor.run { LiveTyper.textBeforeCursor() }
    let output: String
    if !adapt {
      output = typedAnything ? text : String(text.drop { $0 == " " })
    } else if let before {
      // The user typed or moved the cursor since our last insertion → fit to it.
      let continuing = typedAnything && !typedTail.isEmpty && before.hasSuffix(typedTail) && !startsSegment
      output = continuing ? text : StreamingTextJoiner.join(text, after: before, adapt: true)
    } else if !typedAnything {
      output = String(text.drop { $0 == " " })
    } else {
      output = startsSegment ? StreamingTextJoiner.join(text, after: typedTail, adapt: true) : text
    }
    guard !output.isEmpty else { return true }
    await MainActor.run { LiveTyper.type(output, method: method) }
    typedAnything = true
    typedTail = String(output.suffix(2))
    return true
  }
}
