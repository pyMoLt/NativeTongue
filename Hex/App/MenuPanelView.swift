import ComposableArchitecture
import HexCore
import SwiftUI

/// Menu bar icon: idle / literal / recording / processing (plan appendix B).
struct MenuBarIcon: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    Image(imageName)
      .renderingMode(.template)
      .accessibilityLabel(AppBrand.name)
  }

  private var imageName: String {
    if store.transcription.isRecording || store.transcription.isStreaming { return "MenuBarRecording" }
    if store.transcription.isTranscribing { return "MenuBarProcessing" }
    return store.hexSettings.dictationMode == .literal ? "MenuBarLiteral" : "MenuBarIdle"
  }
}

/// Compact glass menu panel (plan 5.10): status, mode, last transcript with
/// copy, profile/language/model in one row, quick actions.
struct MenuPanelView: View {
  @Bindable var store: StoreOf<AppFeature>
  let openSettings: () -> Void
  @Shared(.transcriptionHistory) private var history: TranscriptionHistory
  @Shared(.lastTranscript) private var lastTranscript: LastTranscript? = nil
  @State private var copied = false

  private var settings: HexSettings { store.hexSettings }

  /// In-memory last insertion, else the newest history entry.
  private var latest: (text: String, date: Date, app: String?)? {
    if let lastTranscript { return (lastTranscript.text, lastTranscript.date, lastTranscript.appName) }
    if let entry = history.history.first { return (entry.text, entry.timestamp, entry.sourceAppName) }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      Picker("Mode", selection: Binding(
        get: { settings.dictationMode },
        set: { store.send(.settings(.setDictationMode($0))) }
      )) {
        Text("Normal").tag(DictationMode.normal)
        Text("¶ Literal").tag(DictationMode.literal)
        Text("Streaming").tag(DictationMode.streaming)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.large)

      if settings.dictationMode == .streaming {
        Picker("Streaming style", selection: Binding(
          get: { settings.streaming.punctuationMode == .literal },
          set: { literal in
            store.$hexSettings.withLock { $0.streaming.punctuationMode = literal ? .literal : .automatic }
          }
        )) {
          Text("Normal").tag(false)
          Text("¶ Literal").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
      }

      lastTranscriptCard
      settingsRow
      actions
      Divider()
      escHint
      footer
    }
    .padding(12)
    .frame(width: 300)
    .task { store.send(.refreshModelStatus) }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      Image("MenuBarIdle")
        .renderingMode(.template)
        .resizable()
        .frame(width: 18, height: 18)
        .foregroundStyle(.tint)
      Text(AppBrand.name).font(.headline)
      Spacer()
      statusBadge
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    let (text, color): (String, Color) = store.transcription.isRecording
      ? ("Recording", .red)
      : store.transcription.isTranscribing ? ("Transcribing", .orange)
      : store.modelStatus.loadedModel != nil ? ("Ready", .green) : ("Idle", .secondary)
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.quaternary.opacity(0.5), in: Capsule())
    .accessibilityElement(children: .combine)
  }

  // MARK: Last transcript

  @ViewBuilder
  private var lastTranscriptCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Last transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if let latest {
          Text(latest.date, format: .relative(presentation: .named))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        if let latest {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(latest.text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
          } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
              .font(.caption.weight(.medium))
          }
          .buttonStyle(.glass)
          .controlSize(.small)
          .help("Copy the last transcript")
        }
      }
      if let latest {
        Text(latest.text)
          .font(.callout)
          .lineLimit(4)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text("Nothing dictated yet.")
          .font(.callout)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  // MARK: Profile · language · model

  private var settingsRow: some View {
    let descriptor = try? LocalASRModelCatalog.descriptor(named: settings.activeModel)
    return HStack(spacing: 6) {
      Menu {
        ForEach(ASRProfile.allCases, id: \.self) { profile in
          Button(profile.displayName) { store.send(.settings(.setASRProfile(profile))) }
        }
      } label: {
        Text(settings.asrProfile.displayName)
      }
      .help("Profile")
      Menu {
        Button("Automatic") { store.$hexSettings.withLock { $0.outputLanguage = nil } }
        Button("German") { store.$hexSettings.withLock { $0.outputLanguage = "de" } }
        Button("English") { store.$hexSettings.withLock { $0.outputLanguage = "en" } }
      } label: {
        Text(settings.outputLanguage?.uppercased() ?? "Auto")
      }
      .help("Language")
      Spacer(minLength: 4)
      Text(descriptor?.displayName.components(separatedBy: " · ").first ?? "No model")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if store.modelStatus.loadedModel != nil {
        Button {
          store.send(.unloadModel)
        } label: {
          Image(systemName: "eject")
        }
        .buttonStyle(.borderless)
        .help("Unload model (frees memory)")
        .accessibilityLabel("Unload model")
      }
    }
    .menuStyle(.button)
    .buttonStyle(.glass)
    .controlSize(.small)
    .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: Actions

  private var actions: some View {
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
        Label("Dictation Box", systemImage: "text.below.photo").frame(maxWidth: .infinity)
      }
      Button {
        store.send(.setActiveTab(.files))
        openSettings()
      } label: {
        Label("Transcribe File", systemImage: "waveform.badge.plus").frame(maxWidth: .infinity)
      }
    }
    .buttonStyle(.glass)
    .controlSize(.regular)
  }

  /// Escape cancels a running dictation (recording, transcription and AI
  /// post-processing); it only reaches other apps while nothing is running.
  private var escHint: some View {
    Label {
      Text("cancels the current dictation")
    } icon: {
      Text("esc")
        .font(.caption2.weight(.semibold).monospaced())
        .padding(.horizontal, 4)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5)))
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var footer: some View {
    HStack(spacing: 14) {
      Button("History") {
        store.send(.setActiveTab(.history))
        openSettings()
      }
      Button("Settings…") { openSettings() }
        .keyboardShortcut(",")
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .buttonStyle(.borderless)
    .font(.callout)
    .foregroundStyle(.secondary)
  }
}
