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
        PageHeader(title: "Diktat", subtitle: "Modus, Modell und Sprache für die nächste Aufnahme", symbol: "mic.fill")
        ModeSwitch(mode: settings.dictationMode) { mode in
          store.send(.settings(.setDictationMode(mode)))
        }
        statusCard
        HStack(alignment: .top, spacing: 14) {
          profileCard
          hotkeyCard
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
    Card(title: "Modell", systemImage: "cpu") {
      HStack(alignment: .center, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text(activeDescriptor?.displayName ?? (settings.activeModel.isEmpty ? "Kein Modell gewählt" : settings.activeModel))
            .font(.title3.weight(.semibold))
          HStack(spacing: 6) {
            if let descriptor = activeDescriptor {
              descriptor.literalRating.badge
              if settings.isBiasingEnabled(for: descriptor.internalName), descriptor.capabilities.contextPrompt || !descriptor.capabilities.biasing.isEmpty {
                Badge(text: "Wortschatz-Biasing", systemImage: "text.book.closed", style: .accent)
              }
            }
            if settings.dictationMode == .literal, !settings.literalModel.isEmpty {
              Badge(text: "eigenes Literal-Modell", systemImage: "paragraphsign")
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
              Label("Entladen", systemImage: "eject")
            }
            .buttonStyle(.glass)
            .help("Modell aus dem Arbeitsspeicher entfernen; lädt beim nächsten Diktat neu")
          }
          Button {
            store.send(.setActiveTab(.models))
          } label: {
            Label("Modelle", systemImage: "square.grid.2x2")
          }
          .buttonStyle(.glass)
        }
      }
      if !store.modelBootstrapState.isModelReady {
        Label("Noch kein Modell installiert – unter „Modelle“ eines installieren.", systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
      }
    }
  }

  private var statusLine: String {
    var parts: [String] = []
    if let loaded = store.modelStatus.loadedModel {
      let name = (try? LocalASRModelCatalog.descriptor(named: loaded))?.displayName ?? loaded
      parts.append("Geladen: \(name)")
    } else {
      parts.append("Nicht geladen – lädt beim Drücken der Diktat-Taste")
    }
    if let megabytes = store.modelStatus.footprintMB {
      parts.append("App-Speicher \(ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_048_576, countStyle: .memory))")
    }
    if settings.idleUnloadMinutes > 0 {
      parts.append("entlädt nach \(settings.idleUnloadMinutes) min")
    }
    return parts.joined(separator: " · ")
  }

  // MARK: Profile & language

  private var profileCard: some View {
    Card(title: "Profil & Sprache", systemImage: "person.text.rectangle") {
      Picker("Profil", selection: Binding(
        get: { settings.asrProfile },
        set: { store.send(.settings(.setASRProfile($0))) }
      )) {
        ForEach(ASRProfile.allCases, id: \.self) { profile in
          Text(profile.germanName).tag(profile)
        }
      }
      .pickerStyle(.segmented)
      Text("Das Profil wählt die Wortpakete und deinen Wortschatz für Vorschläge und Korrekturen.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Sprache", selection: Binding(
        get: { settings.outputLanguage ?? "auto" },
        set: { value in store.$hexSettings.withLock { $0.outputLanguage = value == "auto" ? nil : value } }
      )) {
        Text("Automatisch").tag("auto")
        Text("Deutsch").tag("de")
        Text("Englisch").tag("en")
      }
      if settings.outputLanguage == nil, let descriptor = activeDescriptor, !descriptor.capabilities.supportsAutoLanguage {
        Text("\(descriptor.displayName) erkennt die Sprache nicht selbst; es wird Deutsch verwendet.")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  // MARK: Hotkey

  private var hotkeyCard: some View {
    Card(title: "Kurzbefehl", systemImage: "keyboard") {
      Text(Self.describe(settings.hotkey))
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
      Text(settings.useDoubleTapOnly
        ? "Doppelt tippen startet und beendet die Aufnahme."
        : "Halten zum Diktieren · doppelt tippen, um die Aufnahme zu sperren.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Toggle("Diktierbox im \(settings.dictationMode == .literal ? "Literal" : "Normal")-Modus", isOn: Binding(
        get: { settings.dictationBoxEnabled(for: settings.dictationMode) },
        set: { value in
          store.$hexSettings.withLock { settings in
            if settings.dictationMode == .literal { settings.dictationBoxEnabledLiteral = value } else { settings.dictationBoxEnabledNormal = value }
          }
        }
      ))
      .toggleStyle(.switch)
    }
  }

  static func describe(_ hotkey: HotKey) -> String {
    let modifiers = hotkey.modifiers.sorted.map(\.stringValue).joined()
    let key = hotkey.key?.toString ?? ""
    let text = modifiers + key
    return text.isEmpty ? "Nicht festgelegt" : text
  }
}
