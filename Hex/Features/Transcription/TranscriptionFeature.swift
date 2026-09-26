//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import AVFoundation
import CoreGraphics
import Foundation
import HexCore
import Inject
import FluidAudio
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

struct CapturedDictationRequest: Equatable {
  let audioURL: URL
  let duration: TimeInterval
  let model: String
  let mode: DictationMode
  let commandPauseMs: Int
  let language: String?
  let activeVocabulary: String
  let bypassFormatting: Bool
}

/// A wall-clock dependency with an explicit deterministic test value. The generic
/// `DependencyValues.date` key has no test implementation and is especially brittle
/// when an XCTest host links the app and test-support products as separate dylibs.
struct TranscriptionWallClock: Sendable {
  var now: @Sendable () -> Date
}

extension TranscriptionWallClock: DependencyKey {
  static let liveValue = Self(now: { Date() })
  static let testValue = Self(now: { Date(timeIntervalSince1970: 1_234) })
}

extension DependencyValues {
  var transcriptionWallClock: TranscriptionWallClock {
    get { self[TranscriptionWallClock.self] }
    set { self[TranscriptionWallClock.self] = newValue }
  }
}

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State: Equatable {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var liveSessionActive = false
    var liveSessionFailed = false
    var liveUtterances: [AlignedUtterance] = []
    var pendingFinalTranscription: CapturedDictationRequest?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording
    case captureStarted

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(TranscriptionOutput, URL, TimeInterval)
    case sessionTranscriptionResult(String, URL, TimeInterval, isRecovery: Bool)
    case recoverRecording(URL)
    case liveUtteranceResult(AlignedUtterance)
    case livePauseAfterKnown(id: Int, milliseconds: Int)
    case liveSessionFinished(failed: Bool)
    case capturedRecording(CapturedDictationRequest)
    case transcriptionError(Error, URL?)
    case prewarmCompleted(String?)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
    case prewarm
    case liveSession
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.transcriptionWallClock) var wallClock
  @Dependency(\.transcriptPersistence) var transcriptPersistence

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      case .captureStarted:
        return handleCaptureStarted(&state)

      case let .recoverRecording(audioURL):
        return handleRecoveredRecording(&state, audioURL: audioURL)

      case let .liveUtteranceResult(utterance):
        state.liveUtterances.append(utterance)
        return .none

      case let .livePauseAfterKnown(id, milliseconds):
        guard let index = state.liveUtterances.firstIndex(where: { $0.utterance.id == id }) else {
          return .none
        }
        let aligned = state.liveUtterances[index]
        var utterance = aligned.utterance
        utterance.pauseAfterMs = milliseconds
        state.liveUtterances[index] = AlignedUtterance(
          utterance: utterance,
          text: aligned.text,
          language: aligned.language
        )
        return .none

      case let .liveSessionFinished(failed):
        state.liveSessionActive = false
        state.liveSessionFailed = failed
        return startPendingFinalTranscription(&state)

      case let .capturedRecording(request):
        state.pendingFinalTranscription = request
        return startPendingFinalTranscription(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL, duration):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL, duration: duration)

      case let .sessionTranscriptionResult(text, audioURL, duration, isRecovery):
        return handleSessionTranscriptionResult(
          &state,
          text: text,
          audioURL: audioURL,
          duration: duration,
          isRecovery: isRecovery
        )

      case let .prewarmCompleted(errorMessage):
        state.isPrewarming = false
        if let errorMessage {
          state.error = errorMessage
        }
        return .none

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

		  // Process the key event
		  switch hotKeyProcessor.process(keyEvent: keyEvent) {
		  case .startRecording:
			Task { await send(.hotKeyPressed) }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    guard isTranscribing else { return .send(.startRecording) }
    return .concatenate(
      .send(.cancel),
      .send(.startRecording)
    )
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleRecoveredRecording(_ state: inout State, audioURL: URL) -> Effect<Action> {
    guard !state.isRecording, !state.isTranscribing else { return .none }
    let model = state.hexSettings.selectedModel
    guard !model.isEmpty else { return .send(.modelMissing) }

    state.isTranscribing = true
    state.isPrewarming = false
    state.error = nil
    state.sourceAppBundleID = nil
    state.sourceAppName = nil

    let mode = state.hexSettings.dictationMode
    let commandPauseMs = Int((state.hexSettings.spokenCommandPauseSeconds * 1_000).rounded())
    let language = state.hexSettings.outputLanguage
    let activeVocabulary = state.hexSettings.activeVocabulary

    return .run { send in
      do {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0
        let text = try await transcribeCapturedSession(
          audioURL,
          model: model,
          mode: mode,
          commandPauseMs: commandPauseMs,
          language: language,
          activeVocabulary: activeVocabulary,
          bypassFormatting: false
        )
        guard !Task.isCancelled else { return }
        await send(.sessionTranscriptionResult(text, audioURL, duration, isRecovery: true))
      } catch {
        guard !Task.isCancelled else { return }
        transcriptionFeatureLogger.error("Recovered recording transcription failed: \(error.localizedDescription, privacy: .private)")
        await send(.transcriptionError(error, nil))
      }
    }
    .cancellable(id: CancelID.transcription, cancelInFlight: true)
  }

  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    state.liveSessionActive = false
    state.liveSessionFailed = false
    state.liveUtterances.removeAll(keepingCapacity: true)
    state.pendingFinalTranscription = nil
    let model = state.hexSettings.selectedModel
    state.isPrewarming = !model.isEmpty
    let startTime = wallClock.now()
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .cancel(id: CancelID.liveSession),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Local ASR Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        await recording.startRecording()
        guard !Task.isCancelled else { return }
        await send(.captureStarted)
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true),
      model.isEmpty ? .none : .run { send in
        do {
          try await transcription.prewarm(model)
          await send(.prewarmCompleted(nil))
        } catch {
          guard !Task.isCancelled else { return }
          transcriptionFeatureLogger.warning("Model prewarm failed; it will load on demand: \(error.localizedDescription, privacy: .private)")
          await send(.prewarmCompleted("The model will load after recording."))
        }
      }
      .cancellable(id: CancelID.prewarm, cancelInFlight: true)
    )
  }

  func handleCaptureStarted(_ state: inout State) -> Effect<Action> {
    guard state.isRecording else { return .none }
    let model = state.hexSettings.selectedModel
    guard !model.isEmpty else { return .none }

    state.liveSessionActive = true
    state.liveSessionFailed = false
    let mode = state.hexSettings.dictationMode
    let commandPauseMs = Int((state.hexSettings.spokenCommandPauseSeconds * 1_000).rounded())
    let language = state.hexSettings.outputLanguage
    let activeVocabulary = state.hexSettings.activeVocabulary
    let bypassFormatting = state.isRemappingScratchpadFocused
    let biasTerms = activeVocabulary
      .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;")))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let options = RequestOptions(
      language: language,
      punctuation: mode == .literal && !bypassFormatting ? .suppressed : .natural,
      biasTerms: Array(biasTerms.prefix(50))
    )
    let config = SegmenterConfig(minPauseMs: commandPauseMs)

    return .run { [recording, transcription] send in
      let scheduler = LiveTranscriptionScheduler(config: config)
      let audioStream = await recording.liveAudio()
      var failed = false

      for await chunk in audioStream {
        guard !Task.isCancelled else { return }
        guard !failed else { continue }
        do {
          let events = try await scheduler.append(chunk) { samples in
            try await transcription.transcribeSamples(samples, model, options)
          }
          for event in events {
            switch event {
            case let .utteranceTranscribed(utterance):
              await send(.liveUtteranceResult(utterance))
            case let .pauseAfterKnown(id, milliseconds):
              await send(.livePauseAfterKnown(id: id, milliseconds: milliseconds))
            }
          }
        } catch {
          failed = true
          transcriptionFeatureLogger.warning(
            "Live utterance processing stopped; final full-recording pass remains enabled: \(error.localizedDescription, privacy: .private)"
          )
        }
      }

      guard !Task.isCancelled else { return }
      if !failed {
        do {
          let events = try await scheduler.finish { samples in
            try await transcription.transcribeSamples(samples, model, options)
          }
          for event in events {
            switch event {
            case let .utteranceTranscribed(utterance):
              await send(.liveUtteranceResult(utterance))
            case let .pauseAfterKnown(id, milliseconds):
              await send(.livePauseAfterKnown(id: id, milliseconds: milliseconds))
            }
          }
        } catch {
          failed = true
          transcriptionFeatureLogger.warning(
            "Final live utterance processing stopped; full-recording pass remains enabled: \(error.localizedDescription, privacy: .private)"
          )
        }
      }
      await send(.liveSessionFinished(failed: failed))
    }
    .cancellable(id: CancelID.liveSession, cancelInFlight: true)
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = wallClock.now()
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return handleDiscard(&state)
    }

    let model = state.hexSettings.selectedModel
    guard !model.isEmpty else {
      // Defense-in-depth: handleStartRecording already blocks recording when the
      // bootstrap state says no model is ready, but settings can change while a
      // recording is in flight (or the in-memory bootstrap default can race a
      // cold launch). Never hand an empty model name to the transcriber: it
      // silently produces nothing (or junk like "[BLANK_AUDIO]").
      transcriptionFeatureLogger.error("Recording stopped with no transcription model selected; discarding audio")
      return .merge(
        handleDiscard(&state),
        .send(.modelMissing)
      )
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let language = state.hexSettings.outputLanguage
    let dictationMode = state.hexSettings.dictationMode
    let commandPauseMs = Int((state.hexSettings.spokenCommandPauseSeconds * 1_000).rounded())
    let activeVocabulary = state.hexSettings.activeVocabulary
    let bypassFormatting = state.isRemappingScratchpadFocused

    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        do {
          let stopResult = await recording.stopRecording()
          let capturedURL: URL
          switch stopResult {
          case let .captured(url):
            capturedURL = url
          case .ignored(.staleSession):
            transcriptionFeatureLogger.notice("Ignoring transcription stop superseded by a newer recording session")
            return
          case .ignored(.noActiveRecording):
            transcriptionFeatureLogger.error("Recording stopped without captured audio")
            await send(.transcriptionError(RecordingFailure.noCapturedAudio, nil))
            return
          case let .failed(error):
            transcriptionFeatureLogger.error("Recording stop failed: \(error.localizedDescription)")
            await send(.transcriptionError(error, nil))
            return
          }
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)
          await send(.capturedRecording(CapturedDictationRequest(
            audioURL: capturedURL,
            duration: duration,
            model: model,
            mode: dictationMode,
            commandPauseMs: commandPauseMs,
            language: language,
            activeVocabulary: activeVocabulary,
            bypassFormatting: bypassFormatting
          )))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, nil))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }

  func startPendingFinalTranscription(_ state: inout State) -> Effect<Action> {
    guard !state.liveSessionActive,
          let request = state.pendingFinalTranscription
    else { return .none }

    state.pendingFinalTranscription = nil
    return .run { send in
      do {
        let audioFile = try AVAudioFile(forReading: request.audioURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : request.duration
        let text = try await transcribeCapturedSession(
          request.audioURL,
          model: request.model,
          mode: request.mode,
          commandPauseMs: request.commandPauseMs,
          language: request.language,
          activeVocabulary: request.activeVocabulary,
          bypassFormatting: request.bypassFormatting
        )
        guard !Task.isCancelled else { return }
        transcriptionFeatureLogger.notice("Transcribed dictation; output length \(text.count) characters")
        await send(.sessionTranscriptionResult(text, request.audioURL, duration, isRecovery: false))
      } catch {
        guard !Task.isCancelled else { return }
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription, privacy: .private)")
        await send(.transcriptionError(error, nil))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func transcribeCapturedSession(
    _ audioURL: URL,
    model: String,
    mode: DictationMode,
    commandPauseMs: Int,
    language: String?,
    activeVocabulary: String,
    bypassFormatting: Bool
  ) async throws -> String {
    let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(audioURL)
    guard !samples.isEmpty else { return "" }

    let descriptor = try LocalASRModelCatalog.descriptor(named: model)
    let utterances = UtteranceSegmenter.segment(
      samples,
      config: SegmenterConfig(minPauseMs: commandPauseMs)
    )
    let biasTerms = activeVocabulary
      .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;")))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let request = RequestOptions(
      language: language,
      punctuation: mode == .literal && !bypassFormatting ? .suppressed : .natural,
      biasTerms: Array(biasTerms.prefix(50))
    )

    if bypassFormatting {
      return try await transcription.transcribeSamples(samples, model, request).text
    }

    var fullRecordingResult: EngineResult?
    var aligned: [AlignedUtterance]?
    if utterances.isEmpty || descriptor.capabilities.wordTimings {
      let result = try await transcription.transcribeSamples(samples, model, request)
      fullRecordingResult = result
      if !utterances.isEmpty {
        aligned = DictationSessionProcessor.align(result, to: utterances)
        if aligned == nil {
          transcriptionFeatureLogger.notice("Full-recording word timings could not be aligned; using sequential utterance decoding")
        }
      }
    }

    if aligned == nil {
      if utterances.isEmpty {
        guard let result = fullRecordingResult else {
          throw NSError(domain: "DictationSession", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The recording contained no usable speech segments.",
          ])
        }
        let unsegmented = Utterance(
          id: 0,
          range: 0 ..< samples.count,
          pauseBeforeMs: 0,
          pauseAfterMs: 0
        )
        aligned = [AlignedUtterance(
          utterance: unsegmented,
          text: result.text,
          language: result.detectedLanguage
        )]
      } else {
        var sequentialResults: [AlignedUtterance] = []
        sequentialResults.reserveCapacity(utterances.count)
        for utterance in utterances {
          try Task.checkCancellation()
          let lower = max(0, utterance.range.lowerBound)
          let upper = min(samples.count, utterance.range.upperBound)
          guard lower < upper else { continue }
          let result = try await transcription.transcribeSamples(
            Array(samples[lower ..< upper]),
            model,
            request
          )
          sequentialResults.append(AlignedUtterance(
            utterance: utterance,
            text: result.text,
            language: result.detectedLanguage
          ))
        }
        aligned = sequentialResults
      }
    }

    let sessionLanguage = language ?? aligned?.first(where: { $0.language != nil })?.language ?? "de"
    let document = DictationSessionProcessor.makeDocument(
      from: aligned ?? [],
      options: DictationSessionOptions(
        mode: mode,
        commandPauseMs: commandPauseMs,
        language: sessionLanguage,
        formatNumbers: true,
        agentFormatting: mode == .normal
      )
    )
    return document.render(AssemblerOptions(language: sessionLanguage, mode: mode))
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: TranscriptionOutput,
    audioURL: URL,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result.text) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Local ASR.")
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.text.isEmpty else {
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    let remappings = state.hexSettings.wordRemappings
    let dictationMode = state.hexSettings.dictationMode
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = result.text
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = SpokenCommandFormatter.apply(
        result.text,
        mode: dictationMode,
        wordTimings: result.wordTimings,
        minimumCommandPause: state.hexSettings.spokenCommandPauseSeconds
      )
      if output != result.text {
        transcriptionFeatureLogger.info("Applied spoken formatting commands in mode=\(dictationMode.rawValue)")
      }
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      let formattedResult = TranscriptFormattingApplier.apply(
        remappedResult,
        lowercase: state.hexSettings.lowercaseTranscripts,
        removePunctuation: state.hexSettings.removePunctuation
      )
      if formattedResult != remappedResult {
        transcriptionFeatureLogger.info("Applied paste formatting")
      }
      modifiedResult = formattedResult
    }

    guard !modifiedResult.isEmpty else {
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
    let saveTranscriptionHistory = state.hexSettings.saveTranscriptionHistory
    let maxHistoryEntries = state.hexSettings.maxHistoryEntries

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: modifiedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory,
          saveTranscriptionHistory: saveTranscriptionHistory,
          maxHistoryEntries: maxHistoryEntries
        )
      } catch {
        await send(.transcriptionError(error, nil))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleSessionTranscriptionResult(
    _ state: inout State,
    text: String,
    audioURL: URL,
    duration: TimeInterval,
    isRecovery: Bool
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    if ForceQuitCommandDetector.matches(text) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Local ASR.")
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        await MainActor.run { NSApp.terminate(nil) }
      }
    }

    guard !text.isEmpty else {
      if isRecovery {
        state.error = "No speech was recovered. The audio remains available to retry."
        return .none
      }
      return .run { _ in FileManager.default.removeItemIfExists(at: audioURL) }
    }

    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = text
    } else {
      var output = text
      if state.hexSettings.wordRemovalsEnabled {
        output = WordRemovalApplier.apply(output, removals: state.hexSettings.wordRemovals)
      }
      output = WordRemappingApplier.apply(output, remappings: state.hexSettings.wordRemappings)
      modifiedResult = TranscriptFormattingApplier.apply(
        output,
        lowercase: state.hexSettings.lowercaseTranscripts,
        removePunctuation: state.hexSettings.removePunctuation
      )
    }

    guard !modifiedResult.isEmpty else {
      if isRecovery {
        state.error = "No text was recovered. The audio remains available to retry."
        return .none
      }
      return .run { _ in FileManager.default.removeItemIfExists(at: audioURL) }
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
    let saveTranscriptionHistory = state.hexSettings.saveTranscriptionHistory
    let maxHistoryEntries = state.hexSettings.maxHistoryEntries
    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: modifiedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory,
          saveTranscriptionHistory: saveTranscriptionHistory,
          maxHistoryEntries: maxHistoryEntries
        )
      } catch {
        // Keep the source WAV available if persistence/finalization fails so the user can retry.
        await send(.transcriptionError(error, nil))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    
    if let audioURL {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    return .none
  }

  /// Preserve the recovery audio until the paste attempt has completed, while keeping a
  /// separate history copy when transcript history is enabled.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>,
    saveTranscriptionHistory: Bool,
    maxHistoryEntries: Int?
  ) async throws {
    if saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    }

    await pasteboard.paste(result)
    FileManager.default.removeItemIfExists(at: audioURL)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.liveSessionActive = false
    state.liveSessionFailed = false
    state.liveUtterances.removeAll(keepingCapacity: true)
    state.pendingFinalTranscription = nil

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      .cancel(id: CancelID.prewarm),
      .cancel(id: CancelID.liveSession),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        // Stop the recording to release microphone access
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
		soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false
    state.liveSessionActive = false
    state.liveSessionFailed = false
    state.liveUtterances.removeAll(keepingCapacity: true)
    state.pendingFinalTranscription = nil

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .cancel(id: CancelID.prewarm),
      .cancel(id: CancelID.liveSession),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit local asr now" || normalized == "force quit local asr"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
