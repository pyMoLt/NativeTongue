import ComposableArchitecture
import HexCore
import SwiftUI

/// "Shortcut & Recording" (2.6): everything about starting a dictation —
/// dictation key, extra shortcuts, microphone, recording behaviour, sounds.
struct RecordingPageView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus

  private static let systemDefaultTag = "__system_default__"
  private var settings: HexSettings { store.hexSettings }

  var body: some View {
    FlowPage("Recording", subtitle: "How a dictation starts: shortcuts, microphone and sounds", symbol: "keyboard") {
      dictationKeyGroup
      shortcutsGroup
      microphoneGroup
      recordingGroup
      soundGroup
    }
    .task { await store.send(.task).finish() }
  }

  // MARK: Dictation key

  private var dictationKeyGroup: some View {
    let hotKey = settings.hotkey
    let key = store.isSettingHotKey ? nil : hotKey.key
    let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers
    return FlowGroup("Dictation key", footer: "Esc cancels the current dictation: recording, transcription and AI post-processing stop and nothing is inserted. Pressing the dictation key while a dictation is still being processed is ignored.") {
      FlowRow("Shortcut", caption: store.isSettingHotKey ? "Press the new key combination." : "Click the keys to change them.") {
        HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
          .contentShape(Capsule())
          .onTapGesture { store.send(.startSettingHotKey) }
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel("Change dictation shortcut")
      }
      if !store.isSettingHotKey, hotKey.key == nil, !hotKey.modifiers.isEmpty {
        ForEach(hotKey.modifiers.kinds.filter(\.supportsSideSelection), id: \.self) { kind in
          FlowSegmented(
            selection: Binding(
              get: { hotKey.modifiers.side(for: kind) ?? .either },
              set: { store.send(.setModifierSide(kind, $0)) }
            ),
            options: Modifier.Side.allCases.map { FlowOption($0, $0.displayName) }
          )
          .flowRow("\(kind.symbol) \(kind.displayName) key", caption: "Which side of the keyboard counts.")
        }
      }
      FlowSegmented(
        selection: Binding(
          get: { settings.hotkeyTapToggle },
          set: { store.send(.setHotkeyTapToggle($0)) }
        ),
        options: [FlowOption(false, "Hold · double-tap"), FlowOption(true, "Hold · tap to toggle")]
      )
      .flowRow("Key behaviour", caption: settings.hotkeyTapToggle
        ? "Hold to talk and release to stop — or tap once to record hands-free and press again to stop."
        : "Hold to talk and release to stop. Double-tap (if on) records hands-free.")
      if !settings.hotkeyTapToggle {
        Toggle(isOn: Binding(
          get: { settings.doubleTapLockEnabled },
          set: { store.send(.setDoubleTapLockEnabled($0)) }
        )) {
          FlowLabel("Double-tap to lock recording", caption: "Double-tap the key to keep recording hands-free; tap again to stop.")
        }
      }
      if hotKey.key != nil, !settings.hotkeyTapToggle {
        Toggle(isOn: Binding(
          get: { settings.useDoubleTapOnly },
          set: { store.send(.setUseDoubleTapOnly($0)) }
        )) {
          FlowLabel("Use double-tap only")
        }
        .disabled(!settings.doubleTapLockEnabled)
      }
      if hotKey.key == nil {
        FlowRow("Ignore presses shorter than \(settings.minimumKeyTime.formatted(.number.precision(.fractionLength(1)))) s", caption: "Avoids accidental dictations when you use the key for something else.") {
          Slider(
            value: Binding(get: { settings.minimumKeyTime }, set: { store.send(.setMinimumKeyTime($0)) }),
            in: 0.0 ... 2.0,
            step: 0.1
          )
          .frame(width: 180)
        }
      }
    }
  }

  // MARK: Other shortcuts

  private var shortcutsGroup: some View {
    let pasteHotkey = settings.pasteLastTranscriptHotkey
    let key = store.isSettingPasteLastTranscriptHotkey ? nil : pasteHotkey?.key
    let modifiers = store.isSettingPasteLastTranscriptHotkey ? store.currentPasteLastModifiers : (pasteHotkey?.modifiers ?? .init(modifiers: []))
    return FlowGroup("More shortcuts") {
      FlowRow("Paste last transcript", caption: store.isSettingPasteLastTranscriptHotkey
        ? "Use at least one modifier (⌘, ⌥, ⇧, ⌃) plus a key."
        : "Inserts your last dictation again. Click to set a shortcut.") {
        HStack(spacing: 8) {
          HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingPasteLastTranscriptHotkey)
            .contentShape(Capsule())
            .onTapGesture { store.send(.startSettingPasteLastTranscriptHotkey) }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Change paste last transcript shortcut")
          if pasteHotkey != nil, !store.isSettingPasteLastTranscriptHotkey {
            Button {
              store.send(.clearPasteLastTranscriptHotkey)
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.flowQuiet)
            .help("Clear shortcut")
            .accessibilityLabel("Clear shortcut")
          }
        }
      }
      if settings.postProcessing.commandModeEnabled {
        commandModeRow
      }
    }
  }

  /// Command Mode shortcut (C3); shown when Command Mode is on (AI → Advanced).
  private var commandModeRow: some View {
    let hotkey = settings.commandModeHotkey
    let capturing = store.isSettingCommandModeHotkey
    return FlowRow("Command Mode", caption: capturing
      ? "Use at least one modifier (⌘, ⌥, ⇧, ⌃) plus a key."
      : "Select text in any app, press this shortcut and say what to do with it.") {
      HStack(spacing: 8) {
        HotKeyView(
          modifiers: capturing ? store.currentCommandModifiers : (hotkey?.modifiers ?? .init(modifiers: [])),
          key: capturing ? nil : hotkey?.key,
          isActive: capturing
        )
        .contentShape(Capsule())
        .onTapGesture { store.send(.startSettingCommandModeHotkey) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Change Command Mode shortcut")
        if hotkey != nil, !capturing {
          Button {
            store.send(.clearCommandModeHotkey)
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.flowQuiet)
          .help("Clear shortcut")
          .accessibilityLabel("Clear Command Mode shortcut")
        }
      }
    }
  }

  // MARK: Microphone

  private var selectedDeviceTag: Binding<String> {
    Binding(
      get: { settings.selectedMicrophoneID ?? Self.systemDefaultTag },
      set: { store.send(.setSelectedMicrophoneID($0 == Self.systemDefaultTag ? nil : $0)) }
    )
  }

  private var missingSelectedDeviceID: String? {
    guard let selectedID = settings.selectedMicrophoneID,
          !store.availableInputDevices.contains(where: { $0.id == selectedID })
    else { return nil }
    return selectedID
  }

  private var microphoneGroup: some View {
    FlowGroup("Microphone", footer: microphonePermission == .granted ? nil : "Allow microphone access under General to choose a device.") {
      if microphonePermission == .granted {
        FlowRow("Input device", caption: missingSelectedDeviceID != nil ? "The selected device is not connected; the system default is used." : nil) {
          HStack(spacing: 6) {
            Picker("Input device", selection: selectedDeviceTag) {
              Text(store.defaultInputDeviceName.map { "System default (\($0))" } ?? "System default").tag(Self.systemDefaultTag)
              ForEach(store.availableInputDevices) { device in
                Text(device.name).tag(device.id)
              }
              if let missingSelectedDeviceID {
                Text("Unavailable device").tag(missingSelectedDeviceID)
              }
            }
            .id(store.availableInputDevices.map(\.id).joined(separator: "|") + (store.defaultInputDeviceName ?? ""))
            Button {
              store.send(.loadAvailableInputDevices)
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.flowQuiet)
            .help("Refresh input devices")
            .accessibilityLabel("Refresh input devices")
          }
        }
      }
      Toggle(isOn: Binding(
        get: { settings.superFastModeEnabled },
        set: { store.send(.toggleSuperFastMode($0)) }
      )) {
        FlowLabel("Instant start", caption: "Keeps the microphone warm with a short in-memory buffer so the first word is never cut off. macOS shows the microphone indicator while this is on.")
      }
    }
  }

  // MARK: While recording

  private var recordingGroup: some View {
    FlowGroup("While recording") {
      Picker("Other audio", selection: Binding(
        get: { settings.recordingAudioBehavior },
        set: { store.send(.setRecordingAudioBehavior($0)) }
      )) {
        Label("Pause media", systemImage: "pause").tag(RecordingAudioBehavior.pauseMedia)
        Label("Mute volume", systemImage: "speaker.slash").tag(RecordingAudioBehavior.mute)
        Label("Do nothing", systemImage: "hand.raised.slash").tag(RecordingAudioBehavior.doNothing)
      }
      .flowRow("Other audio", caption: "What happens to music and videos while you dictate.")
      Toggle(isOn: Binding(
        get: { settings.preventSystemSleep },
        set: { store.send(.togglePreventSystemSleep($0)) }
      )) {
        FlowLabel("Keep the Mac awake while recording")
      }
    }
  }

  // MARK: Sounds

  private var soundGroup: some View {
    FlowGroup("Sounds") {
      Toggle(isOn: Binding(
        get: { settings.soundEffectsEnabled },
        set: { store.send(.setSoundEffectsEnabled($0)) }
      )) {
        FlowLabel("Soft chimes", caption: "When a dictation starts and ends.")
      }
      FlowRow("Volume \(Int((volumePercentage * 100).rounded())) %") {
        Slider(
          value: Binding(
            get: { volumePercentage },
            set: { store.send(.setSoundEffectsVolume(max(0, min(1, $0)) * HexSettings.baseSoundEffectsVolume)) }
          ),
          in: 0 ... 1
        )
        .frame(width: 180)
        .disabled(!settings.soundEffectsEnabled)
      }
    }
  }

  private var volumePercentage: Double {
    guard HexSettings.baseSoundEffectsVolume > 0 else { return 0 }
    return max(0, min(1, settings.soundEffectsVolume / HexSettings.baseSoundEffectsVolume))
  }
}
