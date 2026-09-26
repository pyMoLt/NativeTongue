import AppKit
import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

@MainActor
final class RecordingRaceTests: XCTestCase {
  func testNewRecordingCancelsPendingDiscardCleanup() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let activeApp = NSWorkspace.shared.frontmostApplication
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("discard-cleanup-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = RecordingProbe(stopURL: stopURL)
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.recording.startRecording = {
        await probe.recordStart()
      }
      $0.recording.stopRecording = {
        await probe.beginStop()
      }
      $0.sleepManagement.preventSleep = { _ in }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.receive(\.captureStarted)
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }

    await probe.waitForPendingStop()

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.receive(\.captureStarted)

    await probe.resumePendingStop()
    await store.finish()

    let counts = await probe.counts()
    XCTAssertEqual(counts.startCalls, 2)
    XCTAssertEqual(counts.stopCalls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopURL.path))
  }

  func testStopGuardIgnoresOnlyStaleSessions() {
    let currentSessionID = UUID()

    XCTAssertFalse(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: currentSessionID
      )
    )
    XCTAssertFalse(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: nil,
        currentSessionID: currentSessionID
      )
    )
    XCTAssertTrue(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: UUID()
      )
    )
  }

  func testCaptureControllerIgnoresCallbacksFromOlderGeneration() {
    XCTAssertTrue(
      SuperFastCaptureController.shouldProcessCallback(
        callbackGeneration: 2,
        currentGeneration: 2
      )
    )
    XCTAssertFalse(
      SuperFastCaptureController.shouldProcessCallback(
        callbackGeneration: 1,
        currentGeneration: 2
      )
    )
  }

  func testFailedRecordingStopEndsTranscription() async {
    let now = Date(timeIntervalSince1970: 1_234)
    var state = Self.makeState()
    state.isRecording = true
    state.recordingStartTime = now
    state.$hexSettings.withLock { settings in
      settings.hotkey = HotKey(key: .a, modifiers: [.command])
      settings.selectedModel = "test-model"
    }
    let stopProbe = FailedStopProbe()
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.recording.stopRecording = { await stopProbe.stopRecording() }
      $0.sleepManagement.allowSleep = {}
    }

    await store.send(.stopRecording) {
      $0.isRecording = false
      $0.isTranscribing = true
      $0.error = nil
      $0.isPrewarming = false
    }
    await stopProbe.waitUntilPending()
    await stopProbe.resume()
    await store.receive(\.transcriptionError) {
      $0.isTranscribing = false
      $0.isPrewarming = false
      $0.error = "Failed to export recorded audio: copy failed"
    }
  }

  func testShortRecordingReleasesSleepAssertion() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("short-recording-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = SleepProbe()
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.recording.startRecording = {}
      $0.recording.stopRecording = { .captured(stopURL) }
      $0.sleepManagement.preventSleep = { _ in
        await probe.recordPreventSleep()
      }
      $0.sleepManagement.allowSleep = {
        await probe.recordAllowSleep()
      }
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      $0.sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    }
    await store.receive(\.captureStarted)
    await store.send(.stopRecording) {
      $0.isRecording = false
    }
    await store.finish()

    let counts = await probe.counts()
    XCTAssertEqual(counts.preventSleepCalls, 1)
    XCTAssertEqual(counts.allowSleepCalls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopURL.path))
  }

  func testDiscardCancelsPendingRecordingStart() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-start-discard-\(UUID().uuidString).wav")
    let sleepProbe = PendingSleepProbe()
    let recordingProbe = RecordingProbe(stopURL: stopURL)
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.recording.startRecording = {
        await recordingProbe.recordStart()
      }
      $0.recording.stopRecording = {
        await recordingProbe.beginImmediateStop()
      }
      $0.sleepManagement.preventSleep = { _ in
        await sleepProbe.preventSleep()
      }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      $0.sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    }
    await sleepProbe.waitUntilPending()
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }
    await sleepProbe.resume()
    await store.finish()

    let counts = await recordingProbe.counts()
    XCTAssertEqual(counts.startCalls, 0)
    XCTAssertEqual(counts.stopCalls, 1)
  }

  func testEmptyTranscriptionDeletesCapturedAudio() async throws {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("empty-transcription-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: audioURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    }

    await store.send(.transcriptionResult(
      TranscriptionOutput(text: "", wordTimings: []),
      audioURL,
      1.25
    ))
    await store.finish()

    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testHistoryUsesRecordingDurationCapturedAtStop() async {
    let duration = 1.25
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("history-duration-\(UUID().uuidString).wav")
    let transcript = Transcript(
      timestamp: Date(timeIntervalSince1970: 1_234),
      text: "hello",
      audioPath: audioURL,
      duration: duration,
      sourceAppBundleID: nil,
      sourceAppName: nil
    )
    let probe = TranscriptPersistenceProbe()
    var state = Self.makeState()
    state.$hexSettings.withLock { $0.saveTranscriptionHistory = true }
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcriptPersistence.save = { text, audioURL, duration, sourceAppBundleID, sourceAppName in
        await probe.record(duration: duration)
        return transcript
      }
      $0.pasteboard.paste = { _ in }
      $0.soundEffects.play = { _ in }
    }

    await store.send(.transcriptionResult(
      TranscriptionOutput(text: "hello", wordTimings: []),
      audioURL,
      duration
    ))
    while await probe.duration == nil {
      await Task.yield()
    }
    store.assert {
      $0.$transcriptionHistory.withLock { $0.history = [transcript] }
    }
    await store.finish()

    let storedDuration = await probe.duration
    XCTAssertEqual(storedDuration, duration)
  }

  func testRecoveryAudioRemainsWhenHistoryPersistenceFails() async throws {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("recovery-persistence-\(UUID().uuidString).wav")
    XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("recovery".utf8)))
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let state = Self.makeState()
    state.$hexSettings.withLock { $0.saveTranscriptionHistory = true }
    let persistenceError = NSError(
      domain: "RecordingRaceTests.Persistence",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "History persistence failed"]
    )
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcriptPersistence.save = { _, _, _, _, _ in throw persistenceError }
    }

    await store.send(.sessionTranscriptionResult("Recovered text", audioURL, 1.0, isRecovery: true))
    await store.receive(\.transcriptionError) {
      $0.error = "History persistence failed"
    }
    await store.finish()

    XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testFinalTranscriptionWaitsUntilLiveSessionFinishes() async throws {
    let audioURL = try Self.makeSilenceWav()
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let probe = LiveFinalTranscriptionProbe()
    var state = Self.makeState()
    state.isTranscribing = true
    state.liveSessionActive = true
    state.$hexSettings.withLock { settings in
      settings.selectedModel = "parakeet-tdt-0.6b-v3-coreml"
      settings.outputLanguage = "en"
    }
    let request = CapturedDictationRequest(
      audioURL: audioURL,
      duration: 1,
      model: "parakeet-tdt-0.6b-v3-coreml",
      mode: .normal,
      commandPauseMs: 450,
      language: "en",
      activeVocabulary: "",
      bypassFormatting: false
    )
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcription.transcribeSamples = { _, _, _ in
        await probe.recordTranscription()
        return EngineResult(text: "ready to paste", detectedLanguage: "en")
      }
      $0.pasteboard.paste = { text in await probe.recordPaste(text) }
      $0.soundEffects.play = { _ in }
    }

    await store.send(.capturedRecording(request)) {
      $0.pendingFinalTranscription = request
    }
    let callsBeforeLiveFinish = await probe.transcriptionCount()
    XCTAssertEqual(callsBeforeLiveFinish, 0)

    await store.send(.liveSessionFinished(failed: false)) {
      $0.liveSessionActive = false
      $0.liveSessionFailed = false
      $0.pendingFinalTranscription = nil
    }
    await store.receive(\.sessionTranscriptionResult) {
      $0.isTranscribing = false
      $0.isPrewarming = false
    }
    await store.finish()

    let transcriptionCount = await probe.transcriptionCount()
    let pastedTexts = await probe.pastedTexts()
    XCTAssertEqual(transcriptionCount, 1)
    XCTAssertEqual(pastedTexts, ["ready to paste"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  private static func makeState() -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      hexSettings: Shared(value: .init()),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: .init())
    )
  }

  private static func makeSilenceWav() throws -> URL {
    let format = try XCTUnwrap(AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    ))
    let frameCount = AVAudioFrameCount(16_000)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(frameCount))

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-session-final-\(UUID().uuidString).wav")
    let audioFile = try AVAudioFile(
      forWriting: url,
      settings: format.settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    try audioFile.write(from: buffer)
    return url
  }
}

private actor LiveFinalTranscriptionProbe {
  private var count = 0
  private var pasted = [String]()

  func recordTranscription() { count += 1 }
  func recordPaste(_ text: String) { pasted.append(text) }
  func transcriptionCount() -> Int { count }
  func pastedTexts() -> [String] { pasted }
}

private actor RecordingProbe {
  private let stopURL: URL
  private var startCalls = 0
  private var stopCalls = 0
  private var stopContinuation: CheckedContinuation<RecordingStopResult, Never>?

  init(stopURL: URL) {
    self.stopURL = stopURL
  }

  func recordStart() {
    startCalls += 1
  }

  func beginStop() async -> RecordingStopResult {
    stopCalls += 1
    return await withCheckedContinuation { continuation in
      stopContinuation = continuation
    }
  }

  func beginImmediateStop() -> RecordingStopResult {
    stopCalls += 1
    return .captured(stopURL)
  }

  func waitForPendingStop() async {
    while stopContinuation == nil {
      await Task.yield()
    }
  }

  func resumePendingStop() {
    stopContinuation?.resume(returning: .captured(stopURL))
    stopContinuation = nil
  }

  func counts() -> (startCalls: Int, stopCalls: Int) {
    (startCalls, stopCalls)
  }
}

private actor SleepProbe {
  private var preventSleepCalls = 0
  private var allowSleepCalls = 0

  func recordPreventSleep() {
    preventSleepCalls += 1
  }

  func recordAllowSleep() {
    allowSleepCalls += 1
  }

  func counts() -> (preventSleepCalls: Int, allowSleepCalls: Int) {
    (preventSleepCalls, allowSleepCalls)
  }
}

private actor PendingSleepProbe {
  private var continuation: CheckedContinuation<Void, Never>?

  func preventSleep() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilPending() async {
    while continuation == nil {
      await Task.yield()
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private actor TranscriptPersistenceProbe {
  private(set) var duration: TimeInterval?

  func record(duration: TimeInterval) {
    self.duration = duration
  }
}

private actor FailedStopProbe {
  private var continuation: CheckedContinuation<RecordingStopResult, Never>?

  func stopRecording() async -> RecordingStopResult {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilPending() async {
    while continuation == nil {
      await Task.yield()
    }
  }

  func resume() {
    continuation?.resume(returning: .failed(.fallbackExportFailed("copy failed")))
    continuation = nil
  }
}
