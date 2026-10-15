import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let streamingLogger = HexLog.streaming

/// What the streaming session reports to the UI.
enum StreamingEvent: Equatable, Sendable {
  /// Recognised but not yet typed (unfinished word, volatile tail).
  case pending(String)
  /// Speech stopped for the configured time; the feature ends the session.
  case silenceTimeout
  /// Text held back while another app was in front could not be typed at the
  /// end of the session; it was put on the clipboard instead (pill shows ⚠︎).
  case textMovedToClipboard
  /// All text typed, microphone released.
  case finished
  case failed(String)
}

/// Parameters for one streaming session.
struct StreamingRequest: Sendable {
  /// Identifies the session for `stop`/`cancel`; these may arrive before `start` runs.
  var id = UUID()
  var settings: HexSettings
  /// Lowercased alias → correct spelling (user vocabulary).
  var aliases: [String: String] = [:]
  /// Normalized trigger words → snippet text (plan B6).
  var snippets: [[String]: String] = [:]
  /// Where finished text goes. Default: typed at the cursor of the frontmost app.
  var sink: (@MainActor @Sendable (String) -> Void)?
}

@DependencyClient
struct StreamingClient {
  /// Opens the microphone and returns; the session then runs on its own and
  /// reports through `onEvent` until `.finished` or `.failed`.
  var start: @Sendable (_ request: StreamingRequest, _ onEvent: @escaping @Sendable (StreamingEvent) -> Void) async -> Void
  /// Ends the session: the remaining text is still typed.
  var stop: @Sendable (_ id: UUID) async -> Void = { _ in }
  /// Ends the session and drops text that was not typed yet.
  var cancel: @Sendable (_ id: UUID) async -> Void = { _ in }
}

extension StreamingClient: DependencyKey {
  static var liveValue: Self {
    let controller = StreamingSessionController()
    return Self(
      start: { await controller.start($0, onEvent: $1) },
      stop: { await controller.stop($0) },
      cancel: { await controller.cancel($0) }
    )
  }

  static var testValue: Self {
    Self(start: { _, _ in }, stop: { _ in }, cancel: { _ in })
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
  /// Parakeet Ultra (Core AI, macOS 27); stored type-erased so the host stays available on macOS 26.
  private var coreAIParakeet: (any StreamingEngine)?
  private var idleTimer = IdleUnloadTimer()
  private var activeSessions = 0

  func sessionStarted() {
    activeSessions += 1
    idleTimer.cancel()
  }

  func sessionFinished(idleMinutes: Int) {
    activeSessions = max(0, activeSessions - 1)
    guard activeSessions == 0, idleMinutes > 0 else { return }
    idleTimer.schedule(after: .seconds(idleMinutes * 60)) { [weak self] generation in
      await self?.unloadIfIdle(generation: generation)
    }
  }

  private func unloadIfIdle(generation: UInt64) async {
    guard idleTimer.isCurrent(generation), activeSessions == 0 else { return }
    idleTimer.detach()
    await unloadAll()
    NotificationCenter.default.post(name: .speechModelIdleUnloaded, object: nil)
  }

  func unloadAll() async {
    idleTimer.cancel()
    await nemotron?.unload()
    await voxtral?.unload()
    await apple?.unload()
    await coreAIParakeet?.unload()
    nemotron = nil
    voxtral = nil
    apple = nil
    coreAIParakeet = nil
  }

  func nemotronEngine(chunkMs: Int) async throws -> NemotronStreamingEngine {
    let engine = nemotron ?? NemotronStreamingEngine()
    await voxtral?.unload()
    voxtral = nil
    try await engine.load(chunkMs: chunkMs)
    nemotron = engine
    return engine
  }

  func voxtralEngine(delayMs: Int = 480) async throws -> VoxtralStreamingEngine {
    let engine = voxtral ?? VoxtralStreamingEngine()
    await engine.setDelay(milliseconds: delayMs)
    await nemotron?.unload()
    nemotron = nil
    try await engine.load()
    voxtral = engine
    return engine
  }

  @available(macOS 27.0, *)
  func coreAIParakeetEngine() async throws -> any StreamingEngine {
    await nemotron?.unload()
    await voxtral?.unload()
    nemotron = nil
    voxtral = nil
    let engine = (coreAIParakeet as? CoreAIParakeetStreamingEngine) ?? CoreAIParakeetStreamingEngine()
    try await engine.load()
    coreAIParakeet = engine
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
///
/// The microphone opens at once; audio is buffered while the engine loads.
/// A new session may start while the previous one still types its rest: its
/// engine is only started (`begin`) after the previous session has finished,
/// because all sessions share the engine instances of `StreamingEngineHost`.
/// `stop`/`cancel` take effect whenever they arrive, also before or during
/// `start` (they are remembered by session id).
actor StreamingSessionController {
  typealias EngineFactory = @Sendable (LocalASRModelDescriptor, HexSettings) async throws -> any StreamingEngine

  private let recording: RecordingClient
  private let transcription: TranscriptionClient
  private let engineFactory: EngineFactory?
  private let typistEnvironment: TypistEnvironment
  private var current: Session?
  private var lastSessionDone: Task<Void, Never>?
  /// `stop`/`cancel` that arrived before their `start` (bounded).
  private var earlyEnds: [UUID: Session.End] = [:]

  /// The parameters replace the live clients in tests.
  init(
    recording: RecordingClient? = nil,
    transcription: TranscriptionClient? = nil,
    engineFactory: EngineFactory? = nil,
    typistEnvironment: TypistEnvironment = .live
  ) {
    @Dependency(\.recording) var liveRecording
    @Dependency(\.transcription) var liveTranscription
    self.recording = recording ?? liveRecording
    self.transcription = transcription ?? liveTranscription
    self.engineFactory = engineFactory
    self.typistEnvironment = typistEnvironment
  }

  final class Session: Sendable {
    enum End: Sendable { case stop, cancel }
    let id: UUID
    private let state = OSAllocatedUnfairLock(initialState: (end: End?.none, microphoneOpen: false))

    init(id: UUID) { self.id = id }

    var end: End? { state.withLock { $0.end } }
    var isCancelled: Bool { end == .cancel }

    /// Marks the end; returns true when the microphone is open and must be closed by the caller.
    func requestEnd(_ end: End) -> Bool {
      state.withLock { value in
        if value.end != .cancel { value.end = end }
        return value.microphoneOpen
      }
    }

    /// Returns false when the session ended while the microphone was opening.
    func microphoneOpened() -> Bool {
      state.withLock { value in
        guard value.end == nil else { return false }
        value.microphoneOpen = true
        return true
      }
    }

    func dropCancelledOutput() { _ = requestEnd(.cancel) }
  }

  func start(_ request: StreamingRequest, onEvent: @escaping @Sendable (StreamingEvent) -> Void) async {
    if earlyEnds.removeValue(forKey: request.id) != nil {
      // Stopped before it started: nothing was recorded.
      onEvent(.finished)
      return
    }
    let session = Session(id: request.id)
    current = session
    let settings = request.settings
    let descriptor: LocalASRModelDescriptor
    do {
      descriptor = try LocalASRModelCatalog.descriptor(named: settings.model(for: .streaming))
    } catch {
      if current === session { current = nil }
      onEvent(.failed(error.localizedDescription))
      return
    }
    await StreamingEngineHost.shared.sessionStarted()
    let language = settings.outputLanguage

    await recording.startStreamingRecording()
    let audio = await recording.liveAudio()
    guard session.microphoneOpened() else {
      // Stop/Esc arrived while the microphone opened.
      await closeMicrophone()
      await StreamingEngineHost.shared.sessionFinished(idleMinutes: settings.idleUnloadMinutes)
      onEvent(.finished)
      return
    }
    let previous = lastSessionDone
    let queue = SampleQueue()
    let typistEnvironment = typistEnvironment
    let frontmostApp = await typistEnvironment.frontmostApp()

    // Read the bounded live stream promptly; the engine may be slower than realtime
    // and is still loading at first.
    let reader = Task.detached {
      for await chunk in audio { await queue.push(chunk.samples) }
      await queue.close()
    }

    let processing = Task.detached {
      var processorOptions = StreamingTextProcessor.Options(
        settings: settings.streaming,
        language: language,
        englishCommands: settings.englishCommandsEnabled,
        aliases: request.aliases
      )
      processorOptions.resolveSelfCorrections = settings.textProcessing.resolveSelfCorrections
      var processor = StreamingTextProcessor(options: processorOptions)
      let typist = Typist(
        method: settings.streaming.insertionMethod,
        adapt: settings.streaming.adaptSpacingAndCase,
        appSwitch: settings.streaming.appSwitchBehavior,
        targetApp: frontmostApp,
        sink: request.sink,
        environment: typistEnvironment
      )
      var silence = SilenceTracker(limitSeconds: settings.streaming.autoStopSilenceSeconds)
      let started = Date()
      var audioSamples = 0
      var wasPausing = false
      var checkedUtterance = ""
      let correctionCommands = settings.streaming.correctionCommands && request.sink == nil
      // Earlier sessions finish with the shared engine first.
      await previous?.value
      var holdsModelSlot = false
      do {
        let (engine, reserved) = try await self.makeEngine(descriptor, settings: settings)
        holdsModelSlot = reserved
        if !session.isCancelled {
          try await engine.begin(language: language)
          while let samples = await queue.next() {
            if session.isCancelled { break }
            audioSamples += samples.count
            let update = try await engine.feed(samples)
            await self.deliver(update, processor: &processor, typist: typist, session: session, onEvent: onEvent)
            if silence.add(samples) { onEvent(.silenceTimeout) }
            if silence.isPausing {
              wasPausing = true
              // A correction command spoken as its own utterance („streich das“):
              // it edits what this session typed instead of being typed (plan B1).
              let utterance = await typist.currentSegment + processor.heldBack
              if utterance != checkedUtterance, !session.isCancelled, request.sink == nil {
                checkedUtterance = utterance
                // A snippet trigger spoken on its own becomes the snippet text (plan B6).
                if let snippet = request.snippets[CommandGrammar.normalizedWords(utterance)],
                   await typist.replaceUtterance(with: snippet) {
                  processor.discardHeld()
                  onEvent(.pending(""))
                  continue
                }
                if correctionCommands, let edit = CommandGrammar.editCommand(utterance, english: settings.englishCommandsEnabled),
                   await typist.applyEdit(edit) {
                  processor.discardHeld()
                  onEvent(.pending(""))
                  continue
                }
              }
              // During a speech pause the engine adds nothing new to the last
              // word: type it now instead of waiting for the next word.
              if let rest = processor.releaseHeldWord(), !session.isCancelled {
                _ = await typist.type(rest, startsSegment: false)
                onEvent(.pending(""))
              }
            } else if wasPausing {
              // Speech resumed: the next words form a new utterance.
              wasPausing = false
              checkedUtterance = ""
              await typist.beginSegment()
            }
          }
          let last = try await engine.end()
          if !session.isCancelled {
            await self.deliver(last, processor: &processor, typist: typist, session: session, onEvent: onEvent)
            let rest = processor.flush()
            if !rest.isEmpty { _ = await typist.type(rest, startsSegment: false) }
            if await typist.finish() { onEvent(.textMovedToClipboard) }
          }
        }
        onEvent(.pending(""))
        onEvent(.finished)
        let audioSeconds = Double(audioSamples) / 16_000
        let elapsed = Date().timeIntervalSince(started)
        streamingLogger.notice("Streaming session ended: audio \(audioSeconds, format: .fixed(precision: 1)) s, processed in \(elapsed, format: .fixed(precision: 1)) s")
      } catch {
        streamingLogger.error("Streaming failed: \(error.localizedDescription, privacy: .private)")
        await self.endAfterFailure(session)
        onEvent(.failed(error.localizedDescription))
      }
      if holdsModelSlot { await self.releaseModelSlot() }
      reader.cancel()
      MLXMemoryPolicy.clearCache()
      await StreamingEngineHost.shared.sessionFinished(idleMinutes: settings.idleUnloadMinutes)
    }
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
      // Emulated/Apple engines deliver one utterance per block.
      await typist.beginSegment()
    }
    let ready = processor.push(update.committed)
    if !ready.isEmpty {
      let typed = await typist.type(ready, startsSegment: update.startsSegment)
      if !typed { session.dropCancelledOutput(); onEvent(.silenceTimeout) }
    }
    onEvent(.pending((processor.heldBack + update.pending).trimmingCharacters(in: .whitespaces)))
  }

  func stop(_ id: UUID) async {
    await end(id, .stop)
  }

  func cancel(_ id: UUID) async {
    await end(id, .cancel)
  }

  private func end(_ id: UUID, _ end: Session.End) async {
    guard let session = current, session.id == id else {
      // Not started yet: remember it for `start`. Ids of finished sessions
      // land here too; the bound keeps that harmless.
      if earlyEnds.count >= 16 { earlyEnds.removeAll() }
      earlyEnds[id] = end
      return
    }
    current = nil
    // While the microphone is still opening, `start` closes it.
    guard session.requestEnd(end) else { return }
    await closeMicrophone()
  }

  /// The engine failed while the microphone may still be open.
  private func endAfterFailure(_ session: Session) async {
    guard current === session else { return }
    current = nil
    if session.requestEnd(.cancel) { await closeMicrophone() }
  }

  private func closeMicrophone() async {
    let result = await recording.stopRecording()
    if case let .captured(url) = result { FileManager.default.removeItemIfExists(at: url) }
  }

  private func releaseModelSlot() async {
    await transcription.releaseForStreaming()
  }

  /// The engine, and whether it holds the speech-model slot of the batch
  /// client (native engines; released when the session ends).
  private func makeEngine(_ descriptor: LocalASRModelDescriptor, settings: HexSettings) async throws -> (any StreamingEngine, Bool) {
    if let engineFactory { return (try await engineFactory(descriptor, settings), false) }
    switch descriptor.backend {
    case .nemotronStreamingCoreML, .voxtralRealtimeMLX:
      // Only one speech model is resident: the batch model leaves first and
      // batch jobs (files) wait until this session ends.
      try await transcription.reserveForStreaming()
      do {
        if descriptor.backend == .nemotronStreamingCoreML {
          return (try await StreamingEngineHost.shared.nemotronEngine(chunkMs: settings.streaming.nemotronChunkMs), true)
        }
        return (try await StreamingEngineHost.shared.voxtralEngine(delayMs: settings.streaming.voxtralDelayMs), true)
      } catch {
        await transcription.releaseForStreaming()
        throw error
      }
    case .appleSpeechAnalyzer:
      return (await StreamingEngineHost.shared.appleEngine(), false)
    case .parakeetCoreAI:
      guard #available(macOS 27.0, *) else { throw CoreAIParakeetStore.unsupported() }
      try await transcription.reserveForStreaming()
      do {
        return (try await StreamingEngineHost.shared.coreAIParakeetEngine(), true)
      } catch {
        await transcription.releaseForStreaming()
        throw error
      }
    default:
      await StreamingEngineHost.shared.unloadAll()
      let model = descriptor.internalName
      let language = settings.outputLanguage
      let keepPunctuation = settings.streaming.punctuationMode != .literal
      return (EmulatedStreamingEngine(
        pauseMs: settings.streaming.emulatedPauseMs,
        maxBlockSeconds: settings.streaming.emulatedMaxBlockSeconds
      ) { [transcription] samples in
        let options = RequestOptions(language: language, punctuation: keepPunctuation ? .natural : .suppressed)
        return try await transcription.transcribeSamples(samples, model, options).text
      }, false)
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

/// What the typist needs from the system; replaced in tests.
struct TypistEnvironment: Sendable {
  var frontmostApp: @Sendable () async -> String?
  /// Up to `count` characters before the cursor, if the app exposes them.
  var textBeforeCursor: @Sendable (_ count: Int) async -> String?
  var type: @Sendable (String, StreamingInsertionMethod) async -> Void
  /// Backspaces; only ever for text the typist typed itself.
  var deleteBackward: @Sendable (Int) async -> Void = { _ in }
  /// Text that could not be typed at the end of a session.
  var copyToClipboard: @Sendable (String) async -> Void

  static let live = TypistEnvironment(
    frontmostApp: { await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier } },
    textBeforeCursor: { count in await MainActor.run { LiveTyper.textBeforeCursor(count: count) } },
    type: { text, method in await MainActor.run { LiveTyper.type(text, method: method) } },
    deleteBackward: { count in await MainActor.run { LiveTyper.deleteBackward(count) } },
    copyToClipboard: { text in
      @Dependency(\.pasteboard) var pasteboard
      await pasteboard.copyTransient(text)
    }
  )
}

/// Types text at the cursor and keeps it consistent with what the user typed.
actor Typist {
  let method: StreamingInsertionMethod
  let adapt: Bool
  let appSwitch: StreamingAppSwitchBehavior
  let targetApp: String?
  let sink: (@MainActor @Sendable (String) -> Void)?
  let environment: TypistEnvironment
  private var typedTail = ""
  private var typedAnything = false
  private var heldWhileAway = ""
  /// What this session typed, one segment per utterance (pause or engine
  /// block), for correction commands. Never more than the own insertion.
  private var segments: [String] = [""]

  init(
    method: StreamingInsertionMethod,
    adapt: Bool,
    appSwitch: StreamingAppSwitchBehavior,
    targetApp: String?,
    sink: (@MainActor @Sendable (String) -> Void)?,
    environment: TypistEnvironment = .live
  ) {
    self.method = method
    self.adapt = adapt
    self.appSwitch = appSwitch
    self.targetApp = targetApp
    self.sink = sink
    self.environment = environment
  }

  /// Returns false when the session must stop (user switched apps, setting "stop").
  func type(_ piece: String, startsSegment: Bool) async -> Bool {
    if let sink {
      await MainActor.run { sink(piece) }
      return true
    }
    let frontmost = await environment.frontmostApp()
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
    let before = await environment.textBeforeCursor(2)
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
    await environment.type(output, method)
    typedAnything = true
    typedTail = String(output.suffix(2))
    segments[segments.count - 1] += output
    return true
  }

  /// The next typed text belongs to a new utterance.
  func beginSegment() {
    if !(segments.last ?? "").isEmpty { segments.append("") }
  }

  /// Text typed for the current utterance so far.
  var currentSegment: String { segments.last ?? "" }

  /// Replaces the current utterance (a snippet trigger) with `text`.
  func replaceUtterance(with text: String) async -> Bool {
    guard sink == nil, heldWhileAway.isEmpty else { return false }
    if let targetApp, await environment.frontmostApp() != targetApp { return false }
    let typed = segments.joined()
    if !typed.isEmpty, let before = await environment.textBeforeCursor(typed.count), !typed.hasSuffix(before), !before.hasSuffix(typed) {
      return false
    }
    let earlier = Array(segments.dropLast()).joined()
    let separator = earlier.isEmpty || earlier.last?.isWhitespace == true ? "" : " "
    let result = earlier + separator + text
    let strokes = TextEditPlanner.keystrokes(from: typed, to: result)
    await environment.deleteBackward(strokes.delete)
    if !strokes.insert.isEmpty { await environment.type(strokes.insert, method) }
    segments = [result, ""]
    typedAnything = true
    typedTail = String(result.suffix(2))
    return true
  }

  /// Applies a correction command spoken as the current utterance: its own
  /// typed words go away, then `edit` acts on the earlier segments. False
  /// (nothing changed) when the user left the target app or changed the text
  /// before the cursor, or the text goes into the box.
  func applyEdit(_ edit: EditCommand) async -> Bool {
    guard sink == nil, heldWhileAway.isEmpty else { return false }
    if let targetApp, await environment.frontmostApp() != targetApp { return false }
    let typed = segments.joined()
    if !typed.isEmpty, let before = await environment.textBeforeCursor(typed.count), !typed.hasSuffix(before), !before.hasSuffix(typed) {
      return false
    }
    let earlier = Array(segments.dropLast())
    let planned = TextEditPlanner.apply(edit, to: earlier)
    // „Ersetze den Reifen durch einen neuen“ without that text is dictation.
    if planned == nil, case .replace = edit { return false }
    let edited = planned ?? earlier
    let result = edited.joined()
    let strokes = TextEditPlanner.keystrokes(from: typed, to: result)
    await environment.deleteBackward(strokes.delete)
    if !strokes.insert.isEmpty { await environment.type(strokes.insert, method) }
    segments = edited + [""]
    typedAnything = !result.isEmpty
    typedTail = String(result.suffix(2))
    return true
  }

  /// End of session: text held back while another app was in front is typed
  /// if the user is back in the target app, otherwise it goes to the
  /// clipboard. Returns true in the clipboard case.
  func finish() async -> Bool {
    let held = heldWhileAway.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !held.isEmpty else { return false }
    if let targetApp, await environment.frontmostApp() == targetApp {
      _ = await type("", startsSegment: false)
      return false
    }
    heldWhileAway = ""
    await environment.copyToClipboard(held)
    return true
  }
}
