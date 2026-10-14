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

/// Menu bar panel ("Flow" design, 2.6): status, mode pills, last transcript,
/// profile/language/model chips and quick actions on the colour field.
struct MenuPanelView: View {
  @Bindable var store: StoreOf<AppFeature>
  let openSettings: () -> Void

  var body: some View {
    MenuPanelContent(store: store, openSettings: openSettings)
      .flowThemed(store.hexSettings.appearance)
  }
}

private struct MenuPanelContent: View {
  @Bindable var store: StoreOf<AppFeature>
  let openSettings: () -> Void
  @Shared(.transcriptionHistory) private var history: TranscriptionHistory
  @Shared(.lastTranscript) private var lastTranscript: LastTranscript? = nil
  @State private var copied = false
  @Namespace private var namespace
  @Environment(\.flowTheme) private var theme

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
      modePills
      if settings.dictationMode == .streaming {
        FlowSegmented(
          selection: Binding(
            get: { settings.streaming.punctuationMode == .literal },
            set: { literal in store.$hexSettings.withLock { $0.streaming.punctuationMode = literal ? .literal : .automatic } }
          ),
          options: [FlowOption(false, "Streaming Normal"), FlowOption(true, "Streaming Literal")],
          compact: true
        )
        .frame(maxWidth: .infinity)
      }
      lastTranscriptCard
      chips
      actions
      footer
    }
    .padding(14)
    .frame(width: 320)
    .background(FlowBackdrop(variant: settings.dictationMode == .literal ? 1 : settings.dictationMode == .streaming ? 2 : 0))
    .task { store.send(.refreshModelStatus) }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 9) {
      Image("MenuBarIdle")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 17, height: 17)
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(LinearGradient(colors: [theme.accent, theme.companion], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 8, style: .continuous))
      Text(AppBrand.name).flowFont(.headline, design: .rounded)
      Spacer()
      statusPill
    }
  }

  private var statusPill: some View {
    let (text, color): (String, Color) = store.transcription.isRecording
      ? ("Recording", .red)
      : store.transcription.isTranscribing ? ("Transcribing", .orange)
      : store.modelStatus.loadedModel != nil ? ("Ready", .green) : ("Idle", .secondary)
    return HStack(spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(text).flowFont(.caption, weight: .medium).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 4)
    .flowSurface(Capsule())
    .accessibilityElement(children: .combine)
  }

  // MARK: Mode

  private var modePills: some View {
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 4) {
        modePill(.normal, "Normal", "waveform")
        modePill(.literal, "Literal", "paragraphsign")
        modePill(.streaming, "Streaming", "dot.radiowaves.left.and.right")
      }
    }
  }

  private func modePill(_ mode: DictationMode, _ title: String, _ symbol: String) -> some View {
    let selected = settings.dictationMode == mode
    return Button {
      withAnimation(theme.animation()) { _ = store.send(.settings(.setDictationMode(mode))) }
    } label: {
      VStack(spacing: 3) {
        Image(systemName: symbol).flowFont(size: 14, weight: .semibold)
        Text(title).flowFont(.caption, weight: selected ? .semibold : .regular)
      }
      .foregroundStyle(selected ? Color.white : Color.primary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LinearGradient(colors: [theme.accent, theme.companion], startPoint: .topLeading, endPoint: .bottomTrailing))
            .matchedGeometryEffect(id: "mode", in: namespace)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
    .flowSurface(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
    .accessibilityLabel("\(title) mode")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: Last transcript

  private var lastTranscriptCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Last transcript").flowFont(.caption, weight: .semibold).foregroundStyle(.secondary)
        if let latest {
          Text(latest.date, format: .relative(presentation: .named))
            .flowFont(.caption)
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
          }
          .buttonStyle(.flowCompact)
          .help("Copy the last transcript")
        }
      }
      if let latest {
        Text(latest.text)
          .flowFont(.callout)
          .lineLimit(4)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text("Nothing dictated yet.")
          .flowFont(.callout)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(12)
    .flowPanel()
  }

  // MARK: Profile · language · model

  private var chips: some View {
    let descriptor = try? LocalASRModelCatalog.descriptor(named: settings.activeModel)
    return HStack(spacing: 6) {
      Menu {
        ForEach(settings.profiles.profiles) { profile in
          Button {
            store.send(.selectManualProfile(profile.id))
          } label: {
            Label(profile.name, systemImage: profile.symbol)
          }
        }
        Divider()
        Toggle("Switch by app", isOn: Binding(
          get: { settings.profiles.switchByApp },
          set: { value in store.$hexSettings.withLock { $0.profiles.switchByApp = value } }
        ))
      } label: {
        Label(settings.profiles.profile(id: settings.profiles.manualProfileID).name, systemImage: settings.profiles.profile(id: settings.profiles.manualProfileID).symbol)
      }
      .help(settings.profiles.switchByApp ? "Profile for apps without their own profile" : "Profile")
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
        .flowFont(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if store.modelStatus.loadedModel != nil {
        Button {
          store.send(.unloadModel)
        } label: {
          Image(systemName: "eject")
        }
        .buttonStyle(.flowQuiet)
        .help("Unload model (frees memory)")
        .accessibilityLabel("Unload model")
      }
    }
    .menuStyle(.button)
    .buttonStyle(.flowCompact)
    .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: Actions

  private var actions: some View {
    HStack(spacing: 6) {
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
    .buttonStyle(.flow)
  }

  /// Escape cancels a running dictation (recording, transcription and AI
  /// post-processing); it only reaches other apps while nothing is running.
  private var footer: some View {
    HStack(spacing: 6) {
      Text("esc")
        .flowFont(.caption2, weight: .semibold, monospaced: true)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.secondary.opacity(0.15), in: Capsule())
      Text("cancels")
        .flowFont(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button("History") {
        store.send(.setActiveTab(.history))
        openSettings()
      }
      Button("Settings…") { openSettings() }
        .keyboardShortcut(",")
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .buttonStyle(.flowQuiet)
    .flowFont(.caption)
  }
}
