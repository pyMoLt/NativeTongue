//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

@Reducer
struct AppFeature {
	private enum CancelID {
		case modelMissingFlash
	}

  enum ActiveTab: Equatable, CaseIterable {
    case dictation
    case models
    case vocabulary
    case commands
    case dictationBox
    case postProcessing
    case streaming
    case files
    case history
    case settings
    case remappings
    case about
  }

  struct ModelStatus: Equatable {
    var loadedModel: String?
    var footprintMB: Int?
  }

	@ObservableState
	struct State {
		var transcription: TranscriptionFeature.State = .init()
		var files: FileTranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var lexicon: LexiconFeature.State = .init()
		var dictationBox: DictationBoxFeature.State = .init()
		var activeTab: ActiveTab = .dictation
		var modelStatus = ModelStatus()
		var isOnboardingPresented = false
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case files(FileTranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case lexicon(LexiconFeature.Action)
    case dictationBox(DictationBoxFeature.Action)
    case setActiveTab(ActiveTab)
    case refreshModelStatus
    case modelStatusLoaded(String?, Int?)
    case unloadModel
    case presentOnboarding(Bool)
    case finishOnboarding
    case lexiconMigrated
    case openFiles([URL])
    case exportSettings
    case importSettings
    case settingsImported(SettingsTransfer)
    case settingsTransferFailed(String)
    case task
    case pasteLastTranscript

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus)
    case appActivated
    case modelStatusEvaluated(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcription) var transcription
  @Dependency(\.permissions) var permissions
  @Dependency(\.lexicon) var lexicon

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.files, action: \.files) {
      FileTranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Scope(state: \.lexicon, action: \.lexicon) {
      LexiconFeature()
    }

    Scope(state: \.dictationBox, action: \.dictationBox) {
      DictationBoxFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none
        
      case .task:
        return .merge(
          startPasteLastTranscriptMonitoring(),
          ensureSelectedModelReadiness(),
          startPermissionMonitoring(),
          promptForPendingRecordingRecovery(),
          prepareLexicon(state: state)
        )
        
      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = transcriptionHistory.history.first?.text else {
          return .none
        }
        return .run { _ in
          await pasteboard.paste(lastTranscript)
        }
        
      case .transcription(.modelMissing):
        HexLog.app.notice("Model missing - activating app and switching to models")
        state.activeTab = .models
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for model missing")
            NotificationCenter.default.post(name: .presentSettingsWindow, object: nil)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }
		.cancellable(id: CancelID.modelMissingFlash, cancelInFlight: true)

      case .transcription(.startRecording):
        // Open the dictation box on the first hotkey of a box session (plan 5.8).
        guard state.transcription.isRecording else { return .none }
        return presentBoxIfNeeded(&state)

      case .transcription(.hotKeyPressed) where state.transcription.isStreaming && state.hexSettings.dictationMode == .literal:
        // Literal + streaming in the box: open the box for the new session.
        return presentBoxIfNeeded(&state)

      case let .transcription(.boxStreamedText(text)):
        return .send(.dictationBox(.streamedText(text)))

      case let .transcription(.boxDictationFinished(output, audioURL)):
        return .send(.dictationBox(.dictationFinished(output, audioURL)))

      case .transcription:
        return .none

      case .dictationBox:
        return .none

      case .files:
        return .none

      case .settings(.requestMicrophone):
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
        }

      case .settings(.requestAccessibility):
        return .run { send in
          await permissions.requestAccessibility()
          // Poll for status change (macOS doesn't provide callback)
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .settings(.requestInputMonitoring):
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .settings:
        return .none

      case .history(.navigateToSettings):
        state.activeTab = .settings
        return .none
      case .history:
        return .none
      case .lexicon:
        return .none
		case let .setActiveTab(tab):
			state.activeTab = tab
			return .none

      case .refreshModelStatus:
        return .run { [transcription] send in
          let loaded = await transcription.loadedModel()
          let bytes = await transcription.processFootprintBytes()
          await send(.modelStatusLoaded(loaded, bytes.map { Int($0 / 1_048_576) }))
        }

      case let .modelStatusLoaded(loaded, megabytes):
        state.modelStatus = ModelStatus(loadedModel: loaded, footprintMB: megabytes)
        return .none

      case .unloadModel:
        return .run { [transcription] send in
          await transcription.unloadModel()
          await send(.refreshModelStatus)
        }

      case let .presentOnboarding(presented):
        state.isOnboardingPresented = presented
        return .none

      case .exportSettings:
        let settings = state.hexSettings
        return .run { [lexicon] _ in
          let transfer = SettingsTransfer(settings: settings, userLexicon: await lexicon.userLexicon())
          guard let data = try? transfer.encoded() else { return }
          await MainActor.run {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(AppBrand.name) Settings.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
          }
        }

      case .importSettings:
        return .run { send in
          let url = await MainActor.run { () -> URL? in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
          }
          guard let url else { return }
          do {
            await send(.settingsImported(try SettingsTransfer.decode(Data(contentsOf: url))))
          } catch {
            await send(.settingsTransferFailed(error.localizedDescription))
          }
        }

      case let .settingsImported(transfer):
        let applied = transfer.settingsToApply(onto: state.hexSettings)
        state.$hexSettings.withLock { $0 = applied }
        let lexiconValue = transfer.userLexicon
        return .run { [lexicon] send in
          try? await lexicon.saveUserLexicon(lexiconValue)
          await lexicon.warmUp(applied.activeLexiconPacks)
          await send(.lexicon(.task))
        }

      case let .settingsTransferFailed(message):
        return .run { _ in
          await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Import failed"
            alert.informativeText = message
            alert.runModal()
          }
        }

      case let .openFiles(urls):
        state.activeTab = .files
        return .send(.files(.addFiles(urls)))

      case .lexiconMigrated:
        state.$hexSettings.withLock { $0.hasMigratedLexicon = true }
        return .none

      case .finishOnboarding:
        state.isOnboardingPresented = false
        state.$hexSettings.withLock { $0.hasCompletedV2Onboarding = true }
        return .none

      // Permission handling
      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input))
        }

      case let .permissionsUpdated(mic, acc, input):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        return .none

      case .appActivated:
        // App became active - re-check permissions
        return .send(.checkPermissions)

      case .modelStatusEvaluated:
        return .none
      }
    }
  }
  
  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if user is setting a hotkey
        if isSettingPasteLastTranscriptHotkey {
          return false
        }

        // Check if this matches the paste last transcript hotkey
        guard let pasteHotkey = hexSettings.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers.matchesExactly(pasteHotkey.modifiers) else {
          return false
        }

        // Trigger paste action - use MainActor to avoid escaping send
        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true // Intercept the key event
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

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
        await send(.modelStatusEvaluated(false))
        return
      }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.progress = 1
        } else {
          state.progress = 0
        }
      }
      await send(.modelStatusEvaluated(isReady))
    }
  }

  /// One-time migration of V1 vocabulary/remappings into the user lexicon,
  /// The pack index is built on the first dictation (see TranscriptionFeature).
  private func prepareLexicon(state: State) -> Effect<Action> {
    // Plain values only: no `withLock` on shared settings from a background effect
    // (lock-order deadlock with dependency initialization, see HexAppDelegate).
    let settings = state.hexSettings
    return .run { [lexicon] send in
      if !settings.hasMigratedLexicon {
        do {
          try await lexicon.migrate(settings)
          await send(.lexiconMigrated)
        } catch {
          HexLog.app.error("Lexicon migration failed: \(error.localizedDescription, privacy: .private)")
        }
      }
      // The pack index (~130 MB) is built when dictation starts, not at
      // launch, and released with the idle speech model (audit A13).
    }
  }

  /// Opens the dictation box for a new box session (plan 5.8), also when
  /// Literal streams into the box.
  private func presentBoxIfNeeded(_ state: inout State) -> Effect<Action> {
    let mode = state.hexSettings.dictationMode
    var effects: [Effect<Action>] = []
    if !state.dictationBox.isPresented, state.hexSettings.dictationBoxEnabled(for: mode) {
      let frontmost = NSWorkspace.shared.frontmostApplication
      let isSelf = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
      effects.append(.send(.dictationBox(.present(
        targetBundleID: isSelf ? nil : frontmost?.bundleIdentifier,
        targetAppName: isSelf ? nil : frontmost?.localizedName,
        mode: mode
      ))))
    }
    if state.dictationBox.isPresented || state.hexSettings.dictationBoxEnabled(for: mode) {
      effects.append(.send(.dictationBox(.recordingStarted)))
    }
    return .concatenate(effects)
  }

  private func promptForPendingRecordingRecovery() -> Effect<Action> {
    .run { send in
      guard !isTesting else { return }
      do {
        let store = try RecordingRecoveryStore()
        let pending = try store.pendingRecordings()
        // An unconfirmed dictation box wins: its text already contains all dictations.
        if let draft = DictationBoxDraftStore.load() {
          let restore = await MainActor.run { () -> Bool in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Restore unsent dictation?"
            alert.informativeText = "The dictation box was neither inserted nor discarded (\(BoxTextEditing.wordCount(draft.string)) words). The text is stored only on this Mac."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Discard")
            return alert.runModal() == .alertFirstButtonReturn
          }
          for recording in pending { try? store.remove(recording) }
          if restore {
            await send(.dictationBox(.restoreDraft(draft)))
          } else {
            DictationBoxDraftStore.remove()
          }
          return
        }
        guard let newest = pending.first else { return }

        let response = await MainActor.run { () -> NSApplication.ModalResponse in
          NSApp.activate(ignoringOtherApps: true)
          let alert = NSAlert()
          alert.alertStyle = .warning
          alert.messageText = "Unfinished local dictation found"
          let countDescription = pending.count == 1
            ? "One interrupted recording is still stored on this Mac."
            : "\(pending.count) interrupted recordings are still stored on this Mac."
          let dateString = DateFormatter.localizedString(from: newest.createdAt, dateStyle: .medium, timeStyle: .short)
          alert.informativeText = "\(countDescription) The newest is from \(dateString). Recovering will transcribe it locally."
          alert.addButton(withTitle: "Recover newest")
          alert.addButton(withTitle: "Later")
          alert.addButton(withTitle: "Discard all")
          return alert.runModal()
        }

        switch response {
        case .alertFirstButtonReturn:
          await send(.transcription(.recoverRecording(newest.url)))
        case .alertThirdButtonReturn:
          for recording in pending {
            try store.remove(recording)
          }
          HexLog.app.notice("Discarded pending local recordings count=\(pending.count)")
        default:
          break
        }
      } catch {
        HexLog.app.error("Failed to inspect recording recovery items: \(error.localizedDescription, privacy: .private)")
      }
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      // Initial check on app launch
      await send(.checkPermissions)

      // Monitor app activation events
      for await activation in permissions.observeAppActivation() {
        if case .didBecomeActive = activation {
          await send(.appActivated)
        }
      }

    }
  }

}
