import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// Streaming start/stop lifecycle (audit H1–H4, L1).
@MainActor
final class StreamingLifecycleTests: XCTestCase {
  // MARK: - Reducer

  func testAccidentalChordRightAfterStreamingStartCancelsTheSession() async {
    let probe = StreamingClientProbe()
    let store = makeStore(probe: probe)
    let id = UUID(0)

    await store.send(.hotKeyPressed) {
      $0.isStreaming = true
      $0.streamingSessionID = id
      $0.streamingStartedByPress = true
      $0.recordingStartTime = Date(timeIntervalSince1970: 1_234)
    }
    await probe.waitForStart()
    // Option+L ("@") within the chord window.
    await store.send(.discard) {
      $0.isStreaming = false
      $0.streamingSessionID = nil
      $0.streamingStartedByPress = false
    }
    await probe.waitForCancel()
    let calls = await probe.calls()
    XCTAssertEqual(calls.cancelled, [id])
    XCTAssertEqual(calls.stopped, [])

    await probe.emit(.finished)
    await store.receive(\.streamingEvent)
    await store.finish()
  }

  func testToggleStopWaitsForChordWindowAndAChordKeepsTheSession() async {
    let probe = StreamingClientProbe()
    let clock = TestClock()
    let store = makeStore(probe: probe, clock: clock)
    let id = UUID(0)

    await store.send(.hotKeyPressed) {
      $0.isStreaming = true
      $0.streamingSessionID = id
      $0.streamingStartedByPress = true
      $0.recordingStartTime = Date(timeIntervalSince1970: 1_234)
    }
    await probe.waitForStart()
    await store.send(.hotKeyReleased)

    // A later Option chord while the session runs must not stop it.
    await store.send(.hotKeyPressed) {
      $0.streamingStartedByPress = false
      $0.streamingStopPending = true
    }
    await store.send(.discard) {
      $0.streamingStopPending = false
    }
    await clock.advance(by: .seconds(2))
    var calls = await probe.calls()
    XCTAssertEqual(calls.stopped, [])
    XCTAssertEqual(calls.cancelled, [])

    // A real press stops after the window.
    await store.send(.hotKeyPressed) {
      $0.streamingStopPending = true
    }
    await clock.advance(by: .milliseconds(300))
    await store.receive(\.streamingStopConfirmed) {
      $0.isStreaming = false
      $0.streamingStopPending = false
    }
    await probe.waitForStop()
    calls = await probe.calls()
    XCTAssertEqual(calls.stopped, [id])

    await probe.emit(.finished)
    await store.receive(\.streamingEvent) {
      $0.streamingSessionID = nil
    }
    await store.finish()
  }

  func testStreamEndingOnItsOwnClearsThePill() async {
    let probe = StreamingClientProbe()
    let store = makeStore(probe: probe)
    let id = UUID(0)
    await store.send(.hotKeyPressed) {
      $0.isStreaming = true
      $0.streamingSessionID = id
      $0.streamingStartedByPress = true
      $0.recordingStartTime = Date(timeIntervalSince1970: 1_234)
    }
    await probe.waitForStart()
    await probe.emit(.finished)
    await store.receive(\.streamingEvent) {
      $0.isStreaming = false
      $0.streamingSessionID = nil
      $0.streamingStartedByPress = false
    }
    await store.finish()
  }

  func testHeldTextOnClipboardShowsWarning() async {
    let probe = StreamingClientProbe()
    let clock = TestClock()
    let store = makeStore(probe: probe, clock: clock)
    let id = UUID(0)
    await store.send(.hotKeyPressed) {
      $0.isStreaming = true
      $0.streamingSessionID = id
      $0.streamingStartedByPress = true
      $0.recordingStartTime = Date(timeIntervalSince1970: 1_234)
    }
    await probe.waitForStart()
    await probe.emit(.textMovedToClipboard)
    await store.receive(\.streamingEvent) { $0.showsPolishWarning = true }
    await probe.emit(.finished)
    await store.receive(\.streamingEvent) {
      $0.isStreaming = false
      $0.streamingSessionID = nil
      $0.streamingStartedByPress = false
    }
    await clock.advance(by: .seconds(3))
    await store.receive(\.polishWarningExpired) { $0.showsPolishWarning = false }
    await store.finish()
  }

  // MARK: - Session controller

  func testStopBeforeStartOpensNoMicrophone() async {
    let recorder = RecorderProbe()
    let engine = ScriptedEngine()
    let controller = makeController(recorder: recorder, engine: engine)
    let events = EventLog()
    let request = Self.request()

    await controller.stop(request.id)
    await controller.start(request) { event in Task { await events.append(event) } }

    await events.waitFor(.finished)
    let counts = await recorder.counts()
    XCTAssertEqual(counts.starts, 0)
    let log = await engine.log
    XCTAssertEqual(log, [])
  }

  func testStopWhileMicrophoneOpensClosesItAgain() async {
    let recorder = RecorderProbe(holdStart: true)
    let engine = ScriptedEngine()
    let controller = makeController(recorder: recorder, engine: engine)
    let events = EventLog()
    let request = Self.request()

    let started = Task { await controller.start(request) { event in Task { await events.append(event) } } }
    await recorder.waitForPendingStart()
    await controller.stop(request.id)
    await recorder.resumeStart()
    await started.value

    await events.waitFor(.finished)
    let counts = await recorder.counts()
    XCTAssertEqual(counts.starts, 1)
    XCTAssertEqual(counts.stops, 1, "microphone must be closed again")
    let log = await engine.log
    XCTAssertEqual(log, [], "the engine must not start for a stopped session")
  }

  func testNextSessionBeginsOnlyAfterThePreviousOneEnded() async {
    let recorder = RecorderProbe()
    let engine = ScriptedEngine(holdEnd: true)
    let controller = makeController(recorder: recorder, engine: engine)
    let sink = SinkLog()
    let first = Self.request(sink: sink)
    let second = Self.request(sink: sink)
    let firstEvents = EventLog()
    let secondEvents = EventLog()

    await controller.start(first) { event in Task { await firstEvents.append(event) } }
    await recorder.send([Float](repeating: 0.1, count: 1_600))
    await engine.waitForFeeds(1)
    await controller.stop(first.id)
    await engine.waitForPendingEnd()

    // The user starts again while the first session still finishes.
    await controller.start(second) { event in Task { await secondEvents.append(event) } }
    await recorder.send([Float](repeating: 0.1, count: 1_600))
    try? await Task.sleep(for: .milliseconds(200))
    var log = await engine.log
    XCTAssertEqual(log, ["begin", "feed"], "second begin must wait for the first end")

    await engine.resumeEnd()
    await firstEvents.waitFor(.finished)
    await engine.waitForFeeds(2)
    await controller.stop(second.id)
    await engine.waitForPendingEnd()
    await engine.resumeEnd()
    await secondEvents.waitFor(.finished)
    log = await engine.log
    XCTAssertEqual(log, ["begin", "feed", "end", "begin", "feed", "end"])
    let typed = await sink.text
    XCTAssertEqual(typed.filter { $0 == "w" }.count, 2, "both sessions' words were delivered")
  }

  func testTextHeldWhileAwayGoesToClipboardWhenSessionEndsElsewhere() async {
    let front = FrontmostProbe(app: "com.example.target")
    let clipboard = SinkLog()
    let typed = SinkLog()
    let environment = TypistEnvironment(
      frontmostApp: { await front.app },
      textBeforeCursor: { _ in nil },
      type: { text, _ in await typed.append(text) },
      copyToClipboard: { text in await clipboard.append(text) }
    )
    let typist = Typist(method: .keyboard, adapt: false, appSwitch: .pause, targetApp: "com.example.target", sink: nil, environment: environment)

    _ = await typist.type("Hallo", startsSegment: false)
    await front.set("com.example.browser")
    let held = await typist.type(" Welt", startsSegment: false)
    XCTAssertTrue(held)
    let movedToClipboard = await typist.finish()
    XCTAssertTrue(movedToClipboard)
    let typedText = await typed.text
    let clipboardText = await clipboard.text
    XCTAssertEqual(typedText, "Hallo")
    XCTAssertEqual(clipboardText, "Welt")
  }

  func testTextHeldWhileAwayIsTypedWhenTheUserIsBack() async {
    let front = FrontmostProbe(app: "com.example.browser")
    let clipboard = SinkLog()
    let typed = SinkLog()
    let environment = TypistEnvironment(
      frontmostApp: { await front.app },
      textBeforeCursor: { _ in nil },
      type: { text, _ in await typed.append(text) },
      copyToClipboard: { text in await clipboard.append(text) }
    )
    let typist = Typist(method: .keyboard, adapt: false, appSwitch: .pause, targetApp: "com.example.target", sink: nil, environment: environment)
    _ = await typist.type("Hallo Welt", startsSegment: false)
    await front.set("com.example.target")
    let movedToClipboard = await typist.finish()
    XCTAssertFalse(movedToClipboard)
    let typedText = await typed.text
    let clipboardText = await clipboard.text
    XCTAssertEqual(typedText, "Hallo Welt")
    XCTAssertEqual(clipboardText, "")
  }

  // MARK: - Correction commands (plan B1)

  private func editableTypist(front: FrontmostProbe, typed: SinkLog, deleted: CountLog, before: String? = nil) -> Typist {
    let environment = TypistEnvironment(
      frontmostApp: { await front.app },
      textBeforeCursor: { _ in before },
      type: { text, _ in await typed.append(text) },
      deleteBackward: { count in await deleted.add(count) },
      copyToClipboard: { _ in }
    )
    return Typist(method: .keyboard, adapt: false, appSwitch: .pause, targetApp: "com.example.target", sink: nil, environment: environment)
  }

  func testScratchThatDeletesOnlyTheLastOwnUtterance() async {
    let front = FrontmostProbe(app: "com.example.target")
    let typed = SinkLog(), deleted = CountLog()
    let typist = editableTypist(front: front, typed: typed, deleted: deleted)
    _ = await typist.type("Hallo Welt.", startsSegment: false)
    await typist.beginSegment()
    _ = await typist.type(" Wir treffen uns am Montag", startsSegment: false)
    await typist.beginSegment()
    _ = await typist.type(" Streich das", startsSegment: false)
    let applied = await typist.applyEdit(.deleteLastUtterance)
    XCTAssertTrue(applied)
    let count = await deleted.total
    XCTAssertEqual(count, " Wir treffen uns am Montag Streich das".count)
    let current = await typist.currentSegment
    XCTAssertEqual(current, "")
  }

  func testReplaceInStreamingRetypesOnlyTheChangedTail() async {
    let front = FrontmostProbe(app: "com.example.target")
    let typed = SinkLog(), deleted = CountLog()
    let typist = editableTypist(front: front, typed: typed, deleted: deleted)
    _ = await typist.type("Termin am Montag um zehn.", startsSegment: false)
    await typist.beginSegment()
    _ = await typist.type(" Ersetze Montag durch Dienstag", startsSegment: false)
    let applied = await typist.applyEdit(.replace("Montag", with: "Dienstag"))
    XCTAssertTrue(applied)
    let text = await typed.text
    XCTAssertTrue(text.hasSuffix("Dienstag um zehn."), text)
  }

  func testNoEditAfterTheUserLeftTheAppOrChangedTheText() async {
    let front = FrontmostProbe(app: "com.example.browser")
    let typed = SinkLog(), deleted = CountLog()
    let typist = editableTypist(front: front, typed: typed, deleted: deleted)
    let away = await typist.applyEdit(.deleteLastUtterance)
    XCTAssertFalse(away)

    let back = FrontmostProbe(app: "com.example.target")
    let changed = editableTypist(front: back, typed: typed, deleted: deleted, before: "ganz anderer Text")
    _ = await changed.type("Hallo Welt", startsSegment: false)
    await changed.beginSegment()
    _ = await changed.type(" streich das", startsSegment: false)
    let refused = await changed.applyEdit(.deleteLastUtterance)
    XCTAssertFalse(refused, "the text before the cursor is not ours any more")
    let count = await deleted.total
    XCTAssertEqual(count, 0)
  }

  func testSnippetTriggerIsReplacedByTheSnippet() async {
    let front = FrontmostProbe(app: "com.example.target")
    let typed = SinkLog(), deleted = CountLog()
    let typist = editableTypist(front: front, typed: typed, deleted: deleted)
    _ = await typist.type("Danke.", startsSegment: false)
    await typist.beginSegment()
    _ = await typist.type(" Grußformel", startsSegment: false)
    let replaced = await typist.replaceUtterance(with: "Viele Grüße\nAlex")
    XCTAssertTrue(replaced)
    let count = await deleted.total
    XCTAssertEqual(count, "Grußformel".count, "the space before the trigger stays")
    let text = await typed.text
    XCTAssertTrue(text.hasSuffix("Viele Grüße\nAlex"), text)
  }

  func testReplaceWithoutTheWordsStaysText() async {
    let front = FrontmostProbe(app: "com.example.target")
    let typed = SinkLog(), deleted = CountLog()
    let typist = editableTypist(front: front, typed: typed, deleted: deleted)
    _ = await typist.type("Das Auto ist alt.", startsSegment: false)
    await typist.beginSegment()
    _ = await typist.type(" Ersetze den Reifen durch einen neuen", startsSegment: false)
    let applied = await typist.applyEdit(.replace("den Reifen", with: "einen neuen"))
    XCTAssertFalse(applied)
    let count = await deleted.total
    XCTAssertEqual(count, 0)
  }

  // MARK: - Helpers

  private func makeStore(probe: StreamingClientProbe, clock: TestClock<Duration> = TestClock()) -> TestStoreOf<TranscriptionFeature> {
    var state = TranscriptionFeature.State(
      hexSettings: Shared(value: .init()),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: .init())
    )
    state.$hexSettings.withLock {
      $0.dictationMode = .streaming
      $0.streaming.hotkeyBehavior = .toggle
    }
    return TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcriptionTiming.sleep = { try await clock.sleep(for: $0) }
      $0.transcriptionTiming.newID = { UUID(0) }
      $0.soundEffects.play = { _ in }
      $0.lexicon.streamingAliases = { _, _ in [:] }
      $0.streaming.start = { request, onEvent in await probe.started(request.id, onEvent) }
      $0.streaming.stop = { await probe.stopped($0) }
      $0.streaming.cancel = { await probe.cancelled($0) }
    }
  }

  private func makeController(recorder: RecorderProbe, engine: ScriptedEngine) -> StreamingSessionController {
    var recording = RecordingClient()
    recording.startStreamingRecording = { await recorder.start() }
    recording.liveAudio = { await recorder.stream() }
    recording.stopRecording = { await recorder.stop() }
    var transcription = TranscriptionClient()
    transcription.unloadModel = {}
    return StreamingSessionController(
      recording: recording,
      transcription: transcription,
      engineFactory: { _, _ in engine }
    )
  }

  private static func request(sink: SinkLog? = nil) -> StreamingRequest {
    var settings = HexSettings()
    settings.streaming.autoStopSilenceSeconds = 0
    var request = StreamingRequest(settings: settings)
    if let sink {
      request.sink = { text in Task { await sink.append(text) } }
    } else {
      request.sink = { _ in }
    }
    return request
  }
}

// MARK: - Probes

private actor StreamingClientProbe {
  private var onEvent: (@Sendable (StreamingEvent) -> Void)?
  private var stops: [UUID] = []
  private var cancels: [UUID] = []

  func started(_ id: UUID, _ onEvent: @escaping @Sendable (StreamingEvent) -> Void) { self.onEvent = onEvent }
  func stopped(_ id: UUID) { stops.append(id) }
  func cancelled(_ id: UUID) { cancels.append(id) }
  func emit(_ event: StreamingEvent) { onEvent?(event) }
  func calls() -> (stopped: [UUID], cancelled: [UUID]) { (stops, cancels) }
  func waitForStart() async { while onEvent == nil { await Task.yield() } }
  func waitForStop() async { while stops.isEmpty { await Task.yield() } }
  func waitForCancel() async { while cancels.isEmpty { await Task.yield() } }
}

private actor RecorderProbe {
  private let holdStart: Bool
  private var startContinuation: CheckedContinuation<Void, Never>?
  private var audio: AsyncStream<AudioChunk>.Continuation?
  private var starts = 0
  private var stops = 0

  init(holdStart: Bool = false) { self.holdStart = holdStart }

  func start() async {
    starts += 1
    if holdStart { await withCheckedContinuation { startContinuation = $0 } }
  }

  func waitForPendingStart() async { while startContinuation == nil { await Task.yield() } }
  func resumeStart() { startContinuation?.resume(); startContinuation = nil }

  func stream() -> AsyncStream<AudioChunk> {
    let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    audio = continuation
    return stream
  }

  func send(_ samples: [Float]) { audio?.yield(AudioChunk(samples: samples, startSample: 0)) }

  func stop() -> RecordingStopResult {
    stops += 1
    audio?.finish()
    audio = nil
    return .ignored(.noActiveRecording)
  }

  func counts() -> (starts: Int, stops: Int) { (starts, stops) }
}

private actor ScriptedEngine: StreamingEngine {
  private let holdEnd: Bool
  private(set) var log: [String] = []
  private var feeds = 0
  private var endContinuation: CheckedContinuation<Void, Never>?

  init(holdEnd: Bool = false) { self.holdEnd = holdEnd }

  func begin(language: String?) async throws { log.append("begin") }

  func feed(_ samples: [Float]) async throws -> StreamingUpdate {
    log.append("feed")
    feeds += 1
    return StreamingUpdate(committed: "wort ")
  }

  func end() async throws -> StreamingUpdate {
    if holdEnd { await withCheckedContinuation { endContinuation = $0 } }
    log.append("end")
    return StreamingUpdate()
  }

  func unload() async {}

  func waitForFeeds(_ count: Int) async { while feeds < count { await Task.yield() } }
  func waitForPendingEnd() async { while endContinuation == nil { await Task.yield() } }
  func resumeEnd() { endContinuation?.resume(); endContinuation = nil }
}

private actor EventLog {
  private var events: [StreamingEvent] = []
  func append(_ event: StreamingEvent) { events.append(event) }
  func waitFor(_ event: StreamingEvent) async {
    while !events.contains(event) { await Task.yield() }
  }
}

private actor SinkLog {
  private(set) var text = ""
  func append(_ piece: String) { text += piece }
}

private actor FrontmostProbe {
  private(set) var app: String?
  init(app: String?) { self.app = app }
  func set(_ app: String?) { self.app = app }
}

private actor CountLog {
  private(set) var total = 0
  func add(_ count: Int) { total += count }
}
