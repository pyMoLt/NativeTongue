import ComposableArchitecture
import HexCore
import SwiftUI

/// Start page „Diktat“: status, mode, profile, language, hotkey (plan 5.10).
struct DictationHomeView: View {
  @Bindable var store: StoreOf<AppFeature>

  private var settings: HexSettings { store.hexSettings }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader(title: "Dictation", subtitle: "Mode, model and language for your next dictation", symbol: "mic.fill")
        ModeSwitch(mode: settings.dictationMode) { mode in
          store.send(.settings(.setDictationMode(mode)))
        }
        statusCard
        // Side by side when there is room, stacked in a narrow window.
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 14) {
            profileCard.frame(minWidth: 320)
            hotkeyCard.frame(minWidth: 260)
          }
          VStack(spacing: 14) {
            profileCard
            hotkeyCard
          }
        }
      }
      .padding(LocalASRDesign.pagePadding)
    }
    .task { store.send(.refreshModelStatus) }
  }

  // MARK: Status

  private var activeDescriptor: LocalASRModelDescriptor? {
    try? LocalASRModelCatalog.descriptor(named: settings.activeModel)
  }

  private var statusCard: some View {
    Card(title: "Model", systemImage: "cpu") {
      HStack(alignment: .center, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text(activeDescriptor?.displayName ?? (settings.activeModel.isEmpty ? "No model selected" : settings.activeModel))
            .font(.title3.weight(.semibold))
          HStack(spacing: 6) {
            if let descriptor = activeDescriptor {
              descriptor.literalRating.badge
              if settings.isBiasingEnabled(for: descriptor.internalName), descriptor.capabilities.contextPrompt || !descriptor.capabilities.biasing.isEmpty {
                Badge(text: "Vocabulary biasing", systemImage: "text.book.closed", style: .accent)
              }
            }
            if settings.dictationMode == .literal, !settings.literalModel.isEmpty {
              Badge(text: "separate Literal model", systemImage: "paragraphsign")
            }
          }
          Text(statusLine)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 8) {
          if store.modelStatus.loadedModel != nil {
            Button {
              store.send(.unloadModel)
            } label: {
              Label("Unload", systemImage: "eject")
            }
            .buttonStyle(.glass)
            .help("Free the model's memory; it reloads on the next dictation")
          }
          Button {
            store.send(.setActiveTab(.models))
          } label: {
            Label("Models", systemImage: "square.grid.2x2")
          }
          .buttonStyle(.glass)
        }
      }
      if !store.modelBootstrapState.isModelReady {
        Label("No model installed yet – install one under Models.", systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
      }
    }
  }

  private var statusLine: String {
    var parts: [String] = []
    if let loaded = store.modelStatus.loadedModel {
      let name = (try? LocalASRModelCatalog.descriptor(named: loaded))?.displayName ?? loaded
      parts.append("Loaded: \(name)")
    } else {
      parts.append("Not loaded – loads when you press the dictation key")
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

  private var profileCard: some View {
    Card(title: "Profile & language", systemImage: "person.text.rectangle") {
      Picker("Profile", selection: Binding(
        get: { settings.asrProfile },
        set: { store.send(.settings(.setASRProfile($0))) }
      )) {
        ForEach(ASRProfile.allCases, id: \.self) { profile in
          Text(profile.displayName).tag(profile)
        }
      }
      .pickerStyle(.segmented)
      Text("The profile selects the word packs and your vocabulary used for suggestions and corrections.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Language", selection: Binding(
        get: { settings.outputLanguage ?? "auto" },
        set: { value in store.$hexSettings.withLock { $0.outputLanguage = value == "auto" ? nil : value } }
      )) {
        Text("Automatic").tag("auto")
        Text("German").tag("de")
        Text("English").tag("en")
      }
      if settings.outputLanguage == nil, let descriptor = activeDescriptor, !descriptor.capabilities.supportsAutoLanguage {
        Text("\(descriptor.displayName) cannot detect the language; German is used.")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  // MARK: Hotkey

  private var hotkeyCard: some View {
    Card(title: "Shortcut", systemImage: "keyboard") {
      Text(Self.describe(settings.hotkey))
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
      Text(hotkeyHint)
        .font(.callout)
        .foregroundStyle(.secondary)
      if settings.dictationMode != .streaming {
      Toggle("Dictation box in \(settings.dictationMode == .literal ? "Literal" : "Normal") mode", isOn: Binding(
        get: { settings.dictationBoxEnabled(for: settings.dictationMode) },
        set: { value in
          store.$hexSettings.withLock { settings in
            if settings.dictationMode == .literal { settings.dictationBoxEnabledLiteral = value } else { settings.dictationBoxEnabledNormal = value }
          }
        }
      ))
      .toggleStyle(.switch)
      }
      Label("Esc cancels the current dictation", systemImage: "escape")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var hotkeyHint: String {
    if settings.dictationMode == .streaming {
      return settings.streaming.hotkeyBehavior == .toggle
        ? "Press once to start streaming, press again to stop. You can type in between."
        : "Hold to stream; release to stop."
    }
    return settings.useDoubleTapOnly
      ? "Double-tap starts and stops recording."
      : "Hold to dictate · double-tap to lock recording."
  }

  static func describe(_ hotkey: HotKey) -> String {
    let modifiers = hotkey.modifiers.sorted.map(\.stringValue).joined()
    let key = hotkey.key?.toString ?? ""
    let text = modifiers + key
    return text.isEmpty ? "Not set" : text
  }
}
