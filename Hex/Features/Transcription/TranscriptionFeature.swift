import ComposableArchitecture
import AVFoundation
import CoreGraphics
import Foundation
import HexCore
import Inject
import os
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

struct CapturedDictationRequest: Equatable {
  let audioURL: URL
  let duration: TimeInterval
  let session: DictationSessionRunner.Request
}

extension DictationSessionRunner.Request {
  /// Snapshot of the settings at recording stop (later setting changes do not
  /// affect a dictation that is already being transcribed).
  init(settings: HexSettings, bypassFormatting: Bool) {
    self.init(
      model: settings.activeModel,
      mode: settings.dictationMode,
      commandPauseMs: Int((settings.spokenCommandPauseSeconds * 1_000).rounded()),
      language: settings.outputLanguage,
      profile: settings.asrProfile,
      activePacks: settings.activeLexiconPacks,
      autoReplacePackTerms: settings.autoReplaceTermsLiteral,
      bypassFormatting: bypassFormatting,
      formatNumbers: settings.numberFormattingEnabled,
      agentFormatting: settings.agentFormattingEnabled,
      englishCommands: settings.englishCommandsEnabled,
      resolveSelfCorrections: settings.textProcessing.resolveSelfCorrections,
      spokenPunctuationInNormal: settings.textProcessing.spokenPunctuationInNormal
    )
  }
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

/// Session ids and short waits for the transcription feature. App-local like
/// `TranscriptionWallClock`: the generic `uuid`/`continuousClock` keys cannot be
/// overridden reliably from the hosted test bundle.
struct TranscriptionTiming: Sendable {
  var newID: @Sendable () -> UUID
  var sleep: @Sendable (Duration) async throws -> Void
}

extension TranscriptionTiming: DependencyKey {
  static let liveValue = Self(newID: { UUID() }, sleep: { try await Task.sleep(for: $0) })
  static var testValue: Self {
    let counter = OSAllocatedUnfairLock(initialState: 0)
    return Self(
      newID: { counter.withLock { value in defer { value += 1 }; return UUID(value) } },
      sleep: { try await Task.sleep(for: $0) }
    )
  }
}

extension DependencyValues {
  var transcriptionTiming: TranscriptionTiming {
    get { self[TranscriptionTiming.self] }
    set { self[TranscriptionTiming.self] = newValue }
  }

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
    /// AI post-processing runs before insertion (pill shows ✨).
    var isPolishing: Bool = false
    /// The AI result was not used; the pill shows ⚠︎ briefly.
    var showsPolishWarning: Bool = false
    /// Streaming mode session is running (text is typed while you speak).
    var isStreaming: Bool = false
    var streamingSessionID: UUID?
    /// The latest hotkey press started the current streaming session; an
    /// accidental chord (`.discard`) cancels it again (audit H1).
    var streamingStartedByPress = false
    /// A toggle press asked to stop; it takes effect once the press can no
    /// longer turn out to be an accidental chord (audit H1).
    var streamingStopPending = false
    /// Recognised text not yet typed (pill, last few words).
    var streamingPending: String = ""
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    /// App the current dictation goes to; its profile shapes the session (C2).
    var sessionAppBundleID: String?
    /// Reference context for the AI (C4), captured at recording start; memory only.
    var sessionContext: AIContext?
    /// Recording of the dictation being transcribed or post-processed. Escape
    /// deletes it at once instead of leaving it for recovery (audit M8).
    var activeAudioURL: URL?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.isDictationBoxPresented) var isDictationBoxPresented: Bool = false
    @Shared(.dictationBoxPlainText) var dictationBoxPlainText: String = ""
    @Shared(.lastTranscript) var lastTranscript: LastTranscript? = nil

    /// Settings of this dictation: the global settings with the target app's
    /// profile laid over them (nothing is stored).
    var sessionSettings: HexSettings { hexSettings.effective(forApp: sessionAppBundleID) }
    var sessionProfile: DictationProfile { hexSettings.profiles.profile(forApp: sessionAppBundleID) }
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

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case sessionTranscriptionResult(DictationSessionOutput, URL, TimeInterval, isRecovery: Bool)
    /// Result for the open dictation box (handled by `AppFeature`); the audio stays
    /// in the recovery folder until the box is confirmed or discarded.
    case boxDictationFinished(DictationSessionOutput, URL)
    case recoverRecording(URL)
    case capturedRecording(CapturedDictationRequest)
    case transcriptionError(Error, URL?)
    /// The stop belonged to an older recording session; nothing to transcribe (audit M2).
    case recordingSuperseded
    /// A correction command found another app or field in front: nothing was deleted (⚠︎).
    case insertionEditRefused
    case prewarmCompleted(String?)
    /// AI context of the target app captured at recording start (C4).
    case contextCaptured(AIContext?)
    case polishCompleted(warning: Bool)
    case polishWarningExpired
    case streamingEvent(UUID, StreamingEvent)
    /// The delayed toggle stop is due (see `streamingStopPending`).
    case streamingStopConfirmed(UUID)
    /// Streamed text for the dictation box (Literal + "Streaming in the box").
    case boxStreamedText(String)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
    case prewarm
    case polishWarning
    case streamingStop
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.lexicon) var lexicon
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.llm) var llm
  @Dependency(\.streaming) var streaming
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.transcriptionWallClock) var wallClock
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.insertionEditor) var insertionEditor
  @Dependency(\.transcriptionTiming) var timing

  var body: some ReducerOf<Self> {
    core
    Reduce { state, _ in
      // Mirror the job phase for the hotkey event tap, which cannot read state.
      DictationActivity.update(
        active: state.isRecording || state.isTranscribing || state.isStreaming,
        processing: state.isTranscribing && !state.isRecording
      )
      return .none
    }
  }

  private var core: some ReducerOf<Self> {
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
        if state.isStreaming {
          return requestStreamingStopFromPress(&state)
        }
        if !state.isRecording, !state.isTranscribing {
          state.sessionAppBundleID = Self.dictationTarget(previous: state.sessionAppBundleID)
        }
        if Self.usesStreaming(state.sessionSettings) {
          let effect = startStreaming(&state)
          state.streamingStartedByPress = true
          return effect
        }
        // A press while the previous dictation is still being processed is
        // dropped silently; only Escape cancels a running job (audit A1).
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased where state.isStreaming:
        guard state.hexSettings.streaming.hotkeyBehavior == .hold else { return .none }
        return stopStreaming(&state)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case let .contextCaptured(context):
        state.sessionContext = context
        return .none

      case .stopRecording:
        return handleStopRecording(&state)

      case let .recoverRecording(audioURL):
        return handleRecoveredRecording(&state, audioURL: audioURL)

      case let .capturedRecording(request):
        state.activeAudioURL = request.audioURL
        return startFinalTranscription(request, settings: state.sessionSettings)

      // MARK: - Transcription Results

      case let .sessionTranscriptionResult(output, audioURL, _, _)
        where state.isDictationBoxPresented && !state.isRemappingScratchpadFocused:
        state.isTranscribing = false
        state.isPrewarming = false
        // The box owns the audio from here on.
        state.activeAudioURL = nil
        return .send(.boxDictationFinished(output, audioURL))

      case .boxDictationFinished:
        return .none

      case let .sessionTranscriptionResult(output, audioURL, duration, isRecovery):
        return handleSessionTranscriptionResult(
          &state,
          text: output.text,
          audioURL: audioURL,
          duration: duration,
          isRecovery: isRecovery,
          protectedTerms: output.document.corrections.map(\.replacement),
          edits: output.document.unappliedEdits
        )

      case let .polishCompleted(warning):
        state.isPolishing = false
        state.isTranscribing = false
        state.activeAudioURL = nil
        guard warning else { return .none }
        return showWarning(&state)

      case .polishWarningExpired:
        state.showsPolishWarning = false
        return .none

      case let .streamingEvent(id, event):
        return handleStreamingEvent(&state, id: id, event: event)

      case let .streamingStopConfirmed(id):
        guard state.streamingStopPending, state.isStreaming, state.streamingSessionID == id else { return .none }
        return stopStreaming(&state)

      case .boxStreamedText:
        return .none

      case let .prewarmCompleted(errorMessage):
        state.isPrewarming = false
        if let errorMessage {
          state.error = errorMessage
        }
        return .none

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .recordingSuperseded:
        state.isTranscribing = false
        state.isPrewarming = false
        return .none

      case .insertionEditRefused:
        return showWarning(&state)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        if state.isStreaming {
          return cancelStreaming(&state, playSound: true)
        }
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // An accidental chord right after a streaming press undoes that press.
        if state.isStreaming, state.streamingStopPending {
          state.streamingStopPending = false
          return .cancel(id: CancelID.streamingStop)
        }
        if state.isStreaming, state.streamingStartedByPress {
          return cancelStreaming(&state, playSound: false)
        }
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
        // Streaming in toggle mode toggles on every press already; a locked
        // processor would report the next press as a release and miss the stop.
        let streamingToggle = TranscriptionFeature.usesStreaming(hexSettings) && hexSettings.streaming.hotkeyBehavior == .toggle
        let tapToggle = hexSettings.hotkeyTapToggle && !streamingToggle
        let doubleTapLock = hexSettings.doubleTapLockEnabled && !tapToggle && !streamingToggle
        let useDoubleTapOnly = doubleTapLock && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = doubleTapLock
        hotKeyProcessor.tapToggleEnabled = tapToggle
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          // Escape cancels a running job and is consumed only while one is
          // active, so it never also closes a dialog in the frontmost app.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            let consume = DictationActivity.isJobActive
            Task { await send(.cancel) }
            return consume
          }

		  // Process the key event
		  switch hotKeyProcessor.process(keyEvent: keyEvent) {
		  case .startRecording:
			if DictationActivity.isProcessing {
			  // Dropped silently (audit A1); require a full release first so
			  // the processor does not stay locked while nothing records.
			  hotKeyProcessor.abandonCurrentPress()
			  return useDoubleTapOnly || keyEvent.key != nil
			}
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
    guard !isTranscribing else {
      transcriptionFeatureLogger.notice("Hotkey pressed while processing; dropped")
      return .none
    }
    return .send(.startRecording)
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
    let model = state.hexSettings.activeModel
    guard !model.isEmpty else { return .send(.modelMissing) }

    state.isTranscribing = true
    state.isPrewarming = false
    state.error = nil
    state.sourceAppBundleID = nil
    state.sourceAppName = nil

    let request = CapturedDictationRequest(
      audioURL: audioURL,
      duration: 0,
      session: DictationSessionRunner.Request(settings: state.hexSettings, bypassFormatting: false)
    )
    return runSession(request, isRecovery: true, biasingEnabled: state.hexSettings.isBiasingEnabled(for: model))
  }

  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let model = state.sessionSettings.activeModel
    state.isPrewarming = !model.isEmpty
    let startTime = wallClock.now()
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    state.sessionContext = nil
    let contextSettings = state.sessionSettings.postProcessing.context
    let profileName = state.sessionProfile.name
    let captureContext: Effect<Action> = contextSettings.use != .off
      ? .run { [appName = state.sourceAppName] send in
        let context = await MainActor.run { () -> AIContext in
          var context = AIContext(appName: appName, profileName: profileName)
          if contextSettings.use == .analyzed {
            context.textBeforeCursor = LiveTyper.textBeforeCursor(count: contextSettings.characters)
          }
          return context
        }
        await send(.contextCaptured(context))
      }
      : .none
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "NativeTongue voice recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        await recording.startRecording()
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true),
      Self.preloadPolish(settings: state.sessionSettings, llm: llm),
      captureContext,
      .run { [lexicon, packs = state.sessionSettings.activeLexiconPacks] _ in await lexicon.warmUp(packs) },
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

  /// Loads the AI model while the user is still speaking (setting "preload on hotkey").
  static func preloadPolish(settings: HexSettings, llm: LLMClient) -> Effect<Action> {
    let post = settings.postProcessing
    guard post.enabled, post.autoEnabled, post.preloadOnHotkey,
          let request = automaticPolish(for: Array(repeating: "x", count: post.minimumWords).joined(separator: " "), settings: settings)
    else { return .none }
    return .run { _ in await llm.preload(request.modelID, post) }
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

    let model = state.sessionSettings.activeModel
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
    var sessionRequest = DictationSessionRunner.Request(settings: state.sessionSettings, bypassFormatting: state.isRemappingScratchpadFocused)
    sessionRequest.boxOpen = state.isDictationBoxPresented
    if state.isDictationBoxPresented { sessionRequest.editTarget = state.dictationBoxPlainText }
    let session = sessionRequest

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
            if Task.isCancelled {
              // Escape arrived while the recording was being finalised.
              FileManager.default.removeItemIfExists(at: url)
              return
            }
          case .ignored(.staleSession):
            transcriptionFeatureLogger.notice("Ignoring transcription stop superseded by a newer recording session")
            await send(.recordingSuperseded)
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
            session: session
          )))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, nil))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }

  /// Quality before latency: the whole recording is decoded once after stop
  /// (Whisper keeps its acoustic context, e.g. Turbo 14/14 command words vs.
  /// 12/14 on isolated clips) and the text is aligned to the audio pauses.
  func startFinalTranscription(_ request: CapturedDictationRequest, settings: HexSettings) -> Effect<Action> {
    runSession(request, isRecovery: false, biasingEnabled: settings.isBiasingEnabled(for: request.session.model), diagnosticsEnabled: settings.diagnosticsEnabled)
  }

  func runSession(_ request: CapturedDictationRequest, isRecovery: Bool, biasingEnabled: Bool, diagnosticsEnabled: Bool = false) -> Effect<Action> {
    .run { [transcription, lexicon] send in
      do {
        let audioFile = try AVAudioFile(forReading: request.audioURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : request.duration
        var session = request.session
        if biasingEnabled, !session.bypassFormatting {
          session.biasTerms = await lexicon.biasTerms(session.profile)
        }
        if !session.boxOpen, !isRecovery {
          // Correction commands may refer to the text inserted last.
          session.editTarget = await insertionEditor.lastInsertion()
        }
        if !session.bypassFormatting {
          let user = await lexicon.userLexicon()
          if session.resolveSelfCorrections { session.vocabulary = Set(user.entries.map { $0.term.lowercased() }) }
          session.snippets = TextSnippet.table(user.snippets, language: session.language ?? "de")
        }
        let runner = DictationSessionRunner(
          transcribeSamples: transcription.transcribeSamples,
          corrector: lexicon.corrector
        )
        let started = Date()
        let output = try await runner.run(request.audioURL, request: session)
        guard !Task.isCancelled else { return }
        DiagnosticsStore.record(DiagnosticsRecord(
          kind: "dictation",
          model: session.model,
          mode: session.mode.rawValue,
          audioSeconds: duration,
          processingSeconds: Date().timeIntervalSince(started),
          utterances: output.document.entries.count,
          structuralCommands: output.document.structuralCommandCount,
          editCommands: output.document.unappliedEdits.count,
          lexiconCorrections: output.document.corrections.count
        ), enabled: diagnosticsEnabled)
        transcriptionFeatureLogger.notice("Transcribed dictation; output length \(output.text.count) characters")
        await send(.sessionTranscriptionResult(output, request.audioURL, duration, isRecovery: isRecovery))
      } catch {
        guard !Task.isCancelled else { return }
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription, privacy: .private)")
        let nsError = error as NSError
        DiagnosticsStore.record(DiagnosticsRecord(
          kind: "error", model: request.session.model, mode: request.session.mode.rawValue,
          audioSeconds: request.duration, processingSeconds: 0, errorCode: "\(nsError.domain)#\(nsError.code)"
        ), enabled: diagnosticsEnabled)
        await send(.transcriptionError(error, nil))
      }
    }
    .cancellable(id: CancelID.transcription, cancelInFlight: isRecovery)
  }

}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleSessionTranscriptionResult(
    _ state: inout State,
    text: String,
    audioURL: URL,
    duration: TimeInterval,
    isRecovery: Bool,
    protectedTerms: [String] = [],
    edits: [EditCommand] = []
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.activeAudioURL = nil
    // Correction commands for the text inserted last („streich das“ …): only
    // applied when the same app and field still have the focus (plan B1).
    let edits = isRecovery || state.isRemappingScratchpadFocused ? [] : edits

    if ForceQuitCommandDetector.matches(text) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating NativeTongue.")
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
      return .run { [insertionEditor] send in
        FileManager.default.removeItemIfExists(at: audioURL)
        guard !edits.isEmpty else { return }
        if await insertionEditor.apply(edits) == .targetChanged { await send(.insertionEditRefused) }
      }
    }

    let modifiedResult: String
    // Literal output is final: legacy lowercase/remove-punctuation/remapping
    // settings would destroy spoken punctuation and capitalization.
    if state.isRemappingScratchpadFocused || state.sessionSettings.dictationMode == .literal {
      modifiedResult = text
    } else {
      var output = text
      if state.hexSettings.wordRemovalsEnabled {
        output = WordRemovalApplier.apply(output, removals: state.hexSettings.wordRemovals)
      }
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

    // Context from the text field (C4): analysed on this Mac; names keep
    // their spelling, capitals and spaces fit, the AI gets short hints only.
    let contextSettings = state.sessionSettings.postProcessing.context
    let context = isRecovery || state.isRemappingScratchpadFocused ? nil : state.sessionContext
    let hints = context.flatMap { context in
      contextSettings.use == .analyzed
        ? ContextAnalyzer.analyze(context, isGeneralWord: { SystemWordChecker.shared.isValidWord($0, language: $1) })
        : nil
    }
    var contextualResult = modifiedResult
    if let hints, contextSettings.terms {
      contextualResult = ContextAnalyzer.applyTerms(contextualResult, terms: hints.terms, isGeneralWord: { SystemWordChecker.shared.isValidWord($0, language: $1) }, language: hints.language ?? "de")
    }
    let contextPrompt = context.flatMap { ContextAnalyzer.prompt(hints ?? ContextHints(), context: $0, settings: contextSettings) }
    let continuation = contextSettings.continuation ? hints : nil
    let resultForInsertion = contextualResult

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
    let saveTranscriptionHistory = state.hexSettings.saveTranscriptionHistory
    let maxHistoryEntries = state.hexSettings.maxHistoryEntries
    let polish = isRecovery || state.isRemappingScratchpadFocused ? nil : Self.automaticPolish(for: contextualResult, settings: state.sessionSettings, contextPrompt: contextPrompt)
    let contextTerms = hints?.terms ?? []
    if polish != nil {
      // Still "processing": a hotkey press is dropped and Esc cancels.
      state.isTranscribing = true
      state.isPolishing = true
      state.activeAudioURL = audioURL
    } else {
      state.$lastTranscript.withLock { $0 = LastTranscript(text: resultForInsertion, date: wallClock.now(), appName: sourceAppName) }
    }
    let lastTranscript = state.$lastTranscript
    let now = wallClock.now()
    return .run { [llm, lexicon, insertionEditor] send in
      if !edits.isEmpty, await insertionEditor.apply(edits) == .targetChanged {
        await send(.insertionEditRefused)
      }
      var finalText = resultForInsertion
      var warning = false
      if var request = polish {
        let userTerms = await lexicon.userLexicon().entries.map(\.term).filter { resultForInsertion.localizedCaseInsensitiveContains($0) }
        let fieldTerms = contextTerms.filter { resultForInsertion.localizedCaseInsensitiveContains($0) }
        request.protectedTerms = Array(Set(protectedTerms + userTerms + fieldTerms))
        let outcome = await llm.polish(request, false, nil)
        guard !Task.isCancelled else { return }
        finalText = outcome.text
        warning = outcome.hasWarning
        lastTranscript.withLock { $0 = LastTranscript(text: finalText, date: now, appName: sourceAppName) }
      }
      if let continuation {
        finalText = ContextAnalyzer.adaptInsertion(finalText, hints: continuation)
      }
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: finalText,
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
      if polish != nil { await send(.polishCompleted(warning: warning)) }
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
    state.activeAudioURL = nil
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
      // The leading space that fits the text field is not part of the transcript.
      let transcript = try await transcriptPersistence.save(
        result.trimmingCharacters(in: .whitespaces),
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      let removed = transcriptionHistory.withLock { $0.insertNewest(transcript, limit: maxHistoryEntries) }
      for entry in removed { try? await transcriptPersistence.deleteAudio(entry) }
    }

    await pasteboard.paste(result)
    await insertionEditor.remember(result)
    FileManager.default.removeItemIfExists(at: audioURL)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    let abandonedAudio = state.activeAudioURL
    state.activeAudioURL = nil
    state.isPolishing = false
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      .cancel(id: CancelID.prewarm),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // A cancelled dictation is gone for good; no recovery offer at the next start.
        if let abandonedAudio { FileManager.default.removeItemIfExists(at: abandonedAudio) }
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

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .cancel(id: CancelID.prewarm),
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
    // The dictation box shows its own recording indicator.
    if store.isDictationBoxPresented {
      return .hidden
    } else if store.isStreaming {
      return .streaming
    } else if store.isPolishing {
      return .polishing
    } else if store.isTranscribing {
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
      meter: store.meter,
      mode: store.hexSettings.dictationMode,
      recordingStart: store.recordingStartTime,
      showsWarning: store.showsPolishWarning && !store.isDictationBoxPresented,
      pendingText: store.streamingPending
    )
    .flowThemed(store.hexSettings.appearance)
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Streaming mode

extension TranscriptionFeature {
  /// Streaming mode, or Literal with "streaming in the dictation box".
  static func usesStreaming(_ settings: HexSettings) -> Bool {
    switch settings.dictationMode {
    case .streaming: true
    case .literal: settings.streaming.literalStreamingInBox && settings.dictationBoxEnabledLiteral
    case .normal: false
    }
  }

  func startStreaming(_ state: inout State) -> Effect<Action> {
    let id = timing.newID()
    state.isStreaming = true
    state.streamingSessionID = id
    state.streamingPending = ""
    state.streamingStopPending = false
    state.error = nil
    state.recordingStartTime = wallClock.now()
    var sessionSettings = state.sessionSettings
    let intoBox = sessionSettings.dictationMode == .literal
    if intoBox {
      // Literal in the box: spoken punctuation decides, the model's does not.
      sessionSettings.streaming.punctuationMode = .literal
    }
    let settings = sessionSettings
    return .run { [streaming, lexicon] send in
      soundEffect.play(.startRecording)
      let aliases = await lexicon.streamingAliases(settings.activeLexiconPacks, settings.asrProfile)
      var request = StreamingRequest(id: id, settings: settings, aliases: aliases)
      request.snippets = TextSnippet.table(await lexicon.userLexicon().snippets, language: settings.outputLanguage ?? "de")
      if intoBox {
        request.sink = { text in send(.boxStreamedText(text)) }
      }
      // Events reach the reducer in the order the session reports them (audit L2).
      let (events, continuation) = AsyncStream.makeStream(of: StreamingEvent.self)
      await streaming.start(request) { event in
        continuation.yield(event)
        switch event {
        case .finished, .failed: continuation.finish()
        default: break
        }
      }
      for await event in events {
        await send(.streamingEvent(id, event))
      }
    }
  }

  /// A hotkey press while streaming. In toggle mode a modifier-only press can
  /// still turn out to be a chord (Option+L types "@"), so the stop waits for
  /// the same window the hotkey processor uses before it reports `.discard`.
  func requestStreamingStopFromPress(_ state: inout State) -> Effect<Action> {
    state.streamingStartedByPress = false
    let settings = state.sessionSettings
    guard settings.streaming.hotkeyBehavior != .hold, let id = state.streamingSessionID else {
      return stopStreaming(&state)
    }
    let window = settings.hotkey.key == nil
      ? max(settings.minimumKeyTime, RecordingDecisionEngine.modifierOnlyMinimumDuration)
      : settings.minimumKeyTime
    state.streamingStopPending = true
    return .run { send in
      try await timing.sleep(.seconds(window))
      await send(.streamingStopConfirmed(id))
    }
    .cancellable(id: CancelID.streamingStop, cancelInFlight: true)
  }

  func stopStreaming(_ state: inout State) -> Effect<Action> {
    state.isStreaming = false
    state.streamingPending = ""
    state.streamingStartedByPress = false
    state.streamingStopPending = false
    guard let id = state.streamingSessionID else { return .cancel(id: CancelID.streamingStop) }
    return .merge(
      .cancel(id: CancelID.streamingStop),
      .run { [streaming] _ in
        await streaming.stop(id)
        soundEffect.play(.stopRecording)
      }
    )
  }

  func cancelStreaming(_ state: inout State, playSound: Bool) -> Effect<Action> {
    let id = state.streamingSessionID
    state.isStreaming = false
    state.streamingSessionID = nil
    state.streamingPending = ""
    state.streamingStartedByPress = false
    state.streamingStopPending = false
    return .merge(
      .cancel(id: CancelID.streamingStop),
      .run { [streaming] _ in
        if let id { await streaming.cancel(id) }
        if playSound { soundEffect.play(.cancel) }
      }
    )
  }

  func handleStreamingEvent(_ state: inout State, id: UUID, event: StreamingEvent) -> Effect<Action> {
    let isCurrent = state.streamingSessionID == id
    switch event {
    case let .pending(text):
      if isCurrent, state.isStreaming, state.hexSettings.streaming.showsPendingText {
        state.streamingPending = String(text.split(separator: " ").suffix(6).joined(separator: " "))
      }
      return .none
    case .silenceTimeout:
      guard isCurrent, state.isStreaming else { return .none }
      return stopStreaming(&state)
    case .textMovedToClipboard:
      return showWarning(&state)
    case .finished:
      guard isCurrent else { return .none }
      // Also when the stream ended on its own (device gone): the pill must not stay (audit L1).
      state.streamingSessionID = nil
      state.isStreaming = false
      state.streamingPending = ""
      state.streamingStartedByPress = false
      state.streamingStopPending = false
      return .cancel(id: CancelID.streamingStop)
    case let .failed(message):
      guard isCurrent else { return .none }
      let effect = cancelStreaming(&state, playSound: true)
      state.error = message
      return effect
    }
  }

  /// The pill shows ⚠︎ for a moment.
  func showWarning(_ state: inout State) -> Effect<Action> {
    state.showsPolishWarning = true
    return .run { send in
      try? await timing.sleep(.seconds(2.5))
      await send(.polishWarningExpired)
    }
    .cancellable(id: CancelID.polishWarning, cancelInFlight: true)
  }
}

// MARK: - Automatic AI post-processing

extension TranscriptionFeature {
  /// The AI request for the automatic step, or nil when it should not run.
  /// The app a new dictation goes to. While NativeTongue itself is in front
  /// (dictation box), the previous target app stays.
  static func dictationTarget(previous: String?) -> String? {
    guard !isTesting, let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return previous }
    return app == Bundle.main.bundleIdentifier ? previous : app
  }

  static func automaticPolish(for text: String, settings: HexSettings, contextPrompt: String? = nil) -> PolishRequest? {
    let post = settings.postProcessing
    guard post.enabled, post.autoEnabled else { return nil }
    let modeAllowed = settings.dictationMode == .normal
      || (settings.dictationMode == .literal && post.autoScope == .normalAndLiteralWithoutBox)
    guard modeAllowed else { return nil }
    guard text.split(whereSeparator: \.isWhitespace).count >= post.minimumWords else { return nil }
    // The selected model only; without one the original is inserted with ⚠︎.
    var request = PolishRequest(text: text, style: post.autoStyle, modelID: post.autoModel, settings: post)
    request.context = contextPrompt
    return request
  }
}

// MARK: - Dictation Activity

/// Job phase mirrored from `TranscriptionFeature.State` for the hotkey event tap,
/// which runs outside the store. While a job is active Escape is consumed by
/// NativeTongue; while a finished recording is processing, hotkey presses are
/// dropped (audit A1).
enum DictationActivity {
  private static let flags = OSAllocatedUnfairLock(initialState: (active: false, processing: false))

  static var isJobActive: Bool { flags.withLock { $0.active } }
  static var isProcessing: Bool { flags.withLock { $0.processing } }

  static func update(active: Bool, processing: Bool) {
    flags.withLock { $0 = (active, processing) }
  }
}

// MARK: - Force Quit Command

enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return ["force quit local asr now", "force quit local asr", "force quit nativetongue", "force quit native tongue"].contains(normalized)
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
