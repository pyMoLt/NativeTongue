import ComposableArchitecture
import HexCore
import SwiftUI

/// Menu bar icon: idle / literal / recording / processing (plan appendix B).
struct MenuBarIcon: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    Image(imageName)
      .renderingMode(.template)
      .accessibilityLabel("Local ASR")
  }

  private var imageName: String {
    if store.transcription.isRecording { return "MenuBarRecording" }
    if store.transcription.isTranscribing { return "MenuBarProcessing" }
    return store.hexSettings.dictationMode == .literal ? "MenuBarLiteral" : "MenuBarIdle"
  }
}

/// Glass menu panel (plan 5.10), 340 pt wide.
struct MenuPanelView: View {
  @Bindable var store: StoreOf<AppFeature>
  let openSettings: () -> Void
  @Shared(.transcriptionHistory) private var history: TranscriptionHistory

  private var settings: HexSettings { store.hexSettings }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Picker("Modus", selection: Binding(
        get: { settings.dictationMode },
        set: { store.send(.settings(.setDictationMode($0))) }
      )) {
        Label("Normal", systemImage: "waveform").tag(DictationMode.normal)
        Label("Literal", systemImage: "paragraphsign").tag(DictationMode.literal)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow {
          Text("Profil").foregroundStyle(.secondary)
          Picker("Profil", selection: Binding(
            get: { settings.asrProfile },
            set: { store.send(.settings(.setASRProfile($0))) }
          )) {
            ForEach(ASRProfile.allCases, id: \.self) { Text($0.germanName).tag($0) }
          }
          .labelsHidden()
        }
        GridRow {
          Text("Sprache").foregroundStyle(.secondary)
          Picker("Sprache", selection: Binding(
            get: { settings.outputLanguage ?? "auto" },
            set: { value in store.$hexSettings.withLock { $0.outputLanguage = value == "auto" ? nil : value } }
          )) {
            Text("Automatisch").tag("auto")
            Text("Deutsch").tag("de")
            Text("Englisch").tag("en")
          }
          .labelsHidden()
        }
      }
      .font(.callout)

      modelRow

      Divider()

      HStack(spacing: 8) {
        Button {
          let frontmost = NSWorkspace.shared.frontmostApplication
          let isSelf = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
          store.send(.dictationBox(.present(
            targetBundleID: isSelf ? nil : frontmost?.bundleIdentifier,
            targetAppName: isSelf ? nil : frontmost?.localizedName,
            mode: settings.dictationMode
          )))
        } label: {
          Label("Diktierbox", systemImage: "text.below.photo").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        Button {
          store.send(.setActiveTab(.audioImport))
          openSettings()
        } label: {
          Label("Datei…", systemImage: "doc.badge.waveform").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
      }

      if settings.saveTranscriptionHistory, !history.history.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Letzte Diktate").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(history.history.prefix(3)) { transcript in
            HStack {
              Text(transcript.text).lineLimit(1).truncationMode(.tail).font(.callout)
              Spacer()
              Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript.text, forType: .string)
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.borderless)
              .help("Kopieren")
            }
          }
        }
      }

      Divider()

      HStack {
        Button("Einstellungen …") { openSettings() }
          .buttonStyle(.borderless)
          .keyboardShortcut(",")
        Spacer()
        Button("Beenden") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.borderless)
          .keyboardShortcut("q")
      }
      .font(.callout)
    }
    .padding(14)
    .frame(width: 340)
    .task { store.send(.refreshModelStatus) }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image("MenuBarIdle")
        .renderingMode(.template)
        .resizable()
        .frame(width: 20, height: 20)
        .foregroundStyle(.tint)
      Text("Local ASR").font(.headline)
      Spacer()
      if store.transcription.isRecording {
        Label("Aufnahme", systemImage: "record.circle").foregroundStyle(.red).font(.caption.weight(.semibold))
      } else if store.transcription.isTranscribing {
        ProgressView().controlSize(.small)
      }
      Button(action: openSettings) {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.glass)
      .help("Einstellungen")
    }
  }

  private var modelRow: some View {
    let descriptor = try? LocalASRModelCatalog.descriptor(named: settings.activeModel)
    return HStack(spacing: 8) {
      Image(systemName: "cpu").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(descriptor?.displayName ?? (settings.activeModel.isEmpty ? "Kein Modell" : settings.activeModel))
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(store.modelStatus.loadedModel == nil
          ? "nicht geladen"
          : "geladen\(store.modelStatus.footprintMB.map { " · App \($0) MB" } ?? "")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if store.modelStatus.loadedModel != nil {
        Button("Entladen") { store.send(.unloadModel) }
          .buttonStyle(.glass)
          .controlSize(.small)
      }
    }
  }
}
