import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

/// Settings → Streaming (plan 2.5, section 4.1): the third way to use the app.
/// Words are typed into the frontmost app while you speak; you can type in between.
struct StreamingPageView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var installProgress: Double?
  @State private var installError: String?
  @State private var installedTick = 0

  private var streaming: StreamingSettings { store.hexSettings.streaming }

  private func binding<Value>(_ keyPath: WritableKeyPath<StreamingSettings, Value>) -> Binding<Value> {
    Binding(
      get: { store.hexSettings.streaming[keyPath: keyPath] },
      set: { value in store.$hexSettings.withLock { $0.streaming[keyPath: keyPath] = value } }
    )
  }

  private var activeModel: LocalASRModelDescriptor? {
    try? LocalASRModelCatalog.descriptor(named: store.hexSettings.model(for: .streaming))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader(
          title: "Streaming",
          subtitle: "Words appear in your app while you speak. Pause, type a comma or fix a word, then keep talking.",
          symbol: "dot.radiowaves.left.and.right"
        )
        modeCard
        modelCard
        controlCard
        textCard
        insertionCard
        literalCard
      }
      .padding(LocalASRDesign.pagePadding)
    }
  }

  // MARK: Cards

  private var modeCard: some View {
    Card(title: "Use Streaming", systemImage: "power") {
      Toggle("Streaming mode", isOn: Binding(
        get: { store.hexSettings.dictationMode == .streaming },
        set: { store.send(.setDictationMode($0 ? .streaming : .normal)) }
      ))
      .toggleStyle(.switch)
      Text("Same as choosing Streaming next to Normal and Literal in the menu bar. Off by default.")
        .settingsCaption()
    }
  }

  private var modelCard: some View {
    Card(title: "Model", systemImage: "cpu") {
      Picker("Streaming model", selection: binding(\.model)) {
        Text("Recommended (Nemotron 3.5)").tag("")
        ForEach(LocalASRModelCatalog.bundled.filter { $0.streaming != .none }) { model in
          Text("\(model.displayName.components(separatedBy: " · ").first ?? model.displayName) — \(model.streaming == .native ? "live" : "after pauses")")
            .tag(model.internalName)
        }
      }
      if let activeModel {
        HStack(spacing: 6) {
          activeModel.streaming.badge
          Text(activeModel.streaming == .native
            ? "Text is typed while you speak and never rewritten."
            : "Each block is typed after you pause. Same accuracy as normal dictation, a little later.")
            .settingsCaption()
        }
      }
      if activeModel?.backend == .nemotronStreamingCoreML {
        Picker("Latency ↔ accuracy", selection: binding(\.nemotronChunkMs)) {
          Text("0.56 s · fastest").tag(560)
          Text("1.12 s · balanced").tag(1120)
          Text("2.24 s · most accurate").tag(2240)
          Text("4.48 s").tag(4480)
        }
        nemotronInstallRow
      }
      if activeModel?.streaming == .emulated {
        Stepper("A pause of \(streaming.emulatedPauseMs) ms ends a block", value: binding(\.emulatedPauseMs), in: 250 ... 2_000, step: 50)
        Stepper("Longest block without a pause: \(streaming.emulatedMaxBlockSeconds) s", value: binding(\.emulatedMaxBlockSeconds), in: 4 ... 30)
      }
      Text("Language follows Settings → Language (automatic when the model supports it).")
        .settingsCaption()
    }
  }

  @ViewBuilder
  private var nemotronInstallRow: some View {
    let _ = installedTick
    let chunk = streaming.nemotronChunkMs
    if NemotronStreamingEngine.isInstalled(chunkMs: chunk) {
      Label("This latency tier is installed.", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    } else if let installProgress {
      ProgressView(value: installProgress).frame(maxWidth: 240)
    } else {
      HStack {
        Text("This latency tier is not installed (~611 MB).").font(.caption).foregroundStyle(.orange)
        Button("Install") { install(chunk) }.buttonStyle(.glassProminent).controlSize(.small)
      }
    }
    if let installError {
      Text(installError).font(.caption).foregroundStyle(.red)
    }
  }

  private var controlCard: some View {
    Card(title: "Dictation key", systemImage: "keyboard") {
      Picker("Behaviour", selection: binding(\.hotkeyBehavior)) {
        ForEach(StreamingHotkeyBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      Picker("Stop after silence", selection: binding(\.autoStopSilenceSeconds)) {
        Text("Never").tag(0)
        Text("30 s").tag(30)
        Text("60 s").tag(60)
        Text("120 s").tag(120)
      }
      Picker("When you switch apps", selection: binding(\.appSwitchBehavior)) {
        ForEach(StreamingAppSwitchBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      Label("Esc stops streaming and drops words that were not typed yet.", systemImage: "escape")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// Streaming Normal vs. Streaming Literal; Normal may add spoken commands.
  private var styleBinding: Binding<Bool> {
    Binding(
      get: { store.hexSettings.streaming.punctuationMode == .literal },
      set: { literal in
        store.$hexSettings.withLock { $0.streaming.punctuationMode = literal ? .literal : .automatic }
      }
    )
  }

  private var textCard: some View {
    Card(title: "Punctuation and formatting", systemImage: "text.cursor") {
      Picker("Style", selection: styleBinding) {
        Text("Streaming Normal").tag(false)
        Text("Streaming Literal").tag(true)
      }
      .pickerStyle(.segmented)
      Text(streaming.punctuationMode == .literal
        ? "Only what you say becomes punctuation; the model's own punctuation is removed. Commands work without pauses."
        : "The model sets punctuation and capitals while you speak.")
        .settingsCaption()
      if streaming.punctuationMode == .literal {
        Picker("Spoken commands", selection: binding(\.literalScope)) {
          ForEach(StreamingLiteralScope.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
      } else {
        Toggle("Also understand spoken punctuation (“Komma”, “Klammer auf” …)", isOn: Binding(
          get: { store.hexSettings.streaming.punctuationMode == .combined },
          set: { value in store.$hexSettings.withLock { $0.streaming.punctuationMode = value ? .combined : .automatic } }
        ))
        .toggleStyle(.switch)
        if streaming.punctuationMode == .automatic {
          Picker("Line-break commands", selection: binding(\.voiceCommands)) {
            Text("Off").tag(StreamingVoiceCommands.off)
            Text("“new line” / “new paragraph”").tag(StreamingVoiceCommands.lineBreaksOnly)
          }
        }
      }
      toggle("Numbers, values and units as digits", \.formatNumbers, "“zwei Komma fünf Milligramm” → “2,5 mg”, “zwölf Prozent” → “12 %”, dates → 03.03.2026.")
      toggle("Technical terms and file names", \.codeFormatting, "For coding agents: “README Punkt md” → README.md, identifiers in backticks.")
      toggle("Apply your vocabulary corrections", \.lexiconCorrection, "Known misrecognitions from Vocabulary are replaced (e.g. “Gwen” → Qwen).")
      toggle("Fit spaces and capitals to what you typed", \.adaptSpacingAndCase, "After you type “.” the next word starts with a capital; no double spaces.")
      toggle("Show words that are not typed yet in the pill", \.showsPendingText)
    }
  }

  private var insertionCard: some View {
    Card(title: "Typing", systemImage: "keyboard.badge.ellipsis") {
      Picker("Insert with", selection: binding(\.insertionMethod)) {
        ForEach(StreamingInsertionMethod.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      Text("Keyboard input works in almost every app and never touches the clipboard. Accessibility inserts text directly but some apps ignore it.")
        .settingsCaption()
    }
  }

  private var literalCard: some View {
    Card(title: "Dictation box (Literal mode)", systemImage: "paragraphsign") {
      toggle("Stream into the dictation box in Literal mode", \.literalStreamingInBox,
             "Needs the dictation box in Literal mode. Say punctuation as words (“Komma”, “Punkt”); they are converted right away, without pauses. Afterwards you can correct the text or use ✨.")
    }
  }

  private func toggle(_ title: String, _ keyPath: WritableKeyPath<StreamingSettings, Bool>, _ caption: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(title, isOn: binding(keyPath)).toggleStyle(.switch)
      if let caption { Text(caption).settingsCaption() }
    }
  }

  private func install(_ chunk: Int) {
    installError = nil
    installProgress = 0
    Task {
      do {
        try await NemotronStreamingEngine.install(chunkMs: chunk) { value in
          Task { @MainActor in installProgress = value }
        }
      } catch {
        installError = "Could not install: \(error.localizedDescription)"
      }
      installProgress = nil
      installedTick += 1
    }
  }
}
