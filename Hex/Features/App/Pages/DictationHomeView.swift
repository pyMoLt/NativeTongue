import ComposableArchitecture
import HexCore
import SwiftUI

/// Start page "Dictation": mode, model, profile, language and shortcut.
struct DictationHomeView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.flowTheme) private var theme

  private var settings: HexSettings { store.hexSettings }

  var body: some View {
    FlowPage("Overview", subtitle: "Mode, model and language for your next dictation", symbol: "mic.fill") {
      ModeSwitch(mode: settings.dictationMode) { mode in
        store.send(.settings(.setDictationMode(mode)))
      }
      modelGroup
      profileGroup
      shortcutGroup
    }
    .task { store.send(.refreshModelStatus) }
  }

  // MARK: Model

  private var activeDescriptor: LocalASRModelDescriptor? {
    try? LocalASRModelCatalog.descriptor(named: settings.activeModel)
  }

  private var modelGroup: some View {
    FlowGroup("Model") {
      FlowBlock {
        HStack(alignment: .center, spacing: 14) {
          VStack(alignment: .leading, spacing: 6) {
            Text(activeDescriptor?.displayName ?? (settings.activeModel.isEmpty ? "No model selected" : settings.activeModel))
              .flowFont(.title3, weight: .semibold, design: .rounded)
            FlowLayout(spacing: 6) {
              if let descriptor = activeDescriptor {
                ForEach(descriptor.bestFor, id: \.self) { mode in
                  Badge(text: "Best for \(mode)", systemImage: "star.fill", style: .accent)
                }
                if settings.isBiasingEnabled(for: descriptor.internalName), descriptor.capabilities.contextPrompt || !descriptor.capabilities.biasing.isEmpty {
                  Badge(text: "Vocabulary biasing", systemImage: "text.book.closed", style: .accent)
                }
              }
              if settings.dictationMode == .literal, !settings.literalModel.isEmpty {
                Badge(text: "Separate Literal model", systemImage: "paragraphsign")
              }
              Badge(text: store.modelStatus.loadedModel != nil ? "Loaded" : "Not loaded",
                    systemImage: store.modelStatus.loadedModel != nil ? "checkmark.circle.fill" : "moon.zzz",
                    style: store.modelStatus.loadedModel != nil ? .positive : .neutral)
            }
            Text(statusLine)
              .flowFont(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          VStack(alignment: .trailing, spacing: 6) {
            Button {
              store.send(.setActiveTab(.models))
            } label: {
              Label("Models", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.flow)
            if store.modelStatus.loadedModel != nil {
              Button {
                store.send(.unloadModel)
              } label: {
                Label("Unload", systemImage: "eject")
              }
              .buttonStyle(.flowQuiet)
              .help("Free the model's memory; it reloads on the next dictation")
            }
          }
        }
      }
      if !store.modelBootstrapState.isModelReady {
        FlowNote("No model installed yet – install one under Models.", systemImage: "exclamationmark.triangle.fill", tone: .warning)
      }
    }
  }

  private var statusLine: String {
    var parts: [String] = []
    if let loaded = store.modelStatus.loadedModel {
      let name = (try? LocalASRModelCatalog.descriptor(named: loaded))?.displayName ?? loaded
      parts.append("Loaded: \(name)")
    } else {
      parts.append("Loads when you press the dictation key")
    }
    if let megabytes = store.modelStatus.footprintMB {
      parts.append("App memory \(ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_048_576, countStyle: .memory))")
    }
    if settings.idleUnloadMinutes > 0 {
      parts.append("unloads after \(settings.idleUnloadMinutes) min")
    }
    return parts.joined(separator: " · ")
  }

  // MARK: Profile & language

  private var profileGroup: some View {
    FlowGroup("Profile and language") {
      Picker("Profile", selection: Binding(
        get: { settings.profiles.manualProfileID },
        set: { store.send(.selectManualProfile($0)) }
      )) {
        ForEach(settings.profiles.profiles) { profile in
          Label(profile.name, systemImage: profile.symbol).tag(profile.id)
        }
      }
      .flowRow("Profile", caption: settings.profiles.switchByApp
        ? "For apps without their own profile; Mail, Xcode and others switch automatically (Profiles page)."
        : "Mode, vocabulary and AI style for every dictation (Profiles page).")

      Picker("Language", selection: Binding(
        get: { settings.outputLanguage ?? "auto" },
        set: { value in store.$hexSettings.withLock { $0.outputLanguage = value == "auto" ? nil : value } }
      )) {
        Text("Automatic").tag("auto")
        Text("German").tag("de")
        Text("English").tag("en")
      }
      .flowRow("Language")

      if settings.outputLanguage == nil, let descriptor = activeDescriptor, !descriptor.capabilities.supportsAutoLanguage {
        FlowNote("\(descriptor.displayName) cannot detect the language; German is used.", systemImage: "exclamationmark.triangle.fill", tone: .warning)
      }
    }
  }

  // MARK: Shortcut

  private var shortcutGroup: some View {
    FlowGroup("Shortcut", footer: "Esc cancels the current dictation.") {
      FlowRow(hotkeyHint) {
        Text(Self.describe(settings.hotkey))
          .flowFont(.title3, weight: .semibold, design: .rounded)
          .padding(.horizontal, 14)
          .padding(.vertical, 4)
          .foregroundStyle(theme.accent)
          .background(theme.accent.opacity(0.14), in: Capsule())
      }
      if settings.dictationMode != .streaming {
        Toggle(isOn: Binding(
          get: { settings.dictationBoxEnabled(for: settings.dictationMode) },
          set: { value in
            store.$hexSettings.withLock { settings in
              if settings.dictationMode == .literal { settings.dictationBoxEnabledLiteral = value } else { settings.dictationBoxEnabledNormal = value }
            }
          }
        )) {
          FlowLabel("Dictation box in \(settings.dictationMode == .literal ? "Literal" : "Normal") mode",
                    caption: "Collect and correct the dictation in the box before inserting it.")
        }
      }
    }
  }

  private var hotkeyHint: String {
    if settings.dictationMode == .streaming {
      return settings.streaming.hotkeyBehavior == .toggle
        ? "Press once to start streaming, press again to stop"
        : "Hold to stream; release to stop"
    }
    return settings.useDoubleTapOnly
      ? "Double-tap starts and stops recording"
      : "Hold to dictate · double-tap to lock recording"
  }

  static func describe(_ hotkey: HotKey) -> String {
    let modifiers = hotkey.modifiers.sorted.map(\.stringValue).joined()
    let key = hotkey.key?.toString ?? ""
    let text = modifiers + key
    return text.isEmpty ? "Not set" : text
  }
}
