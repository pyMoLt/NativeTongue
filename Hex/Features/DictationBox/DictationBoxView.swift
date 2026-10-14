import ComposableArchitecture
import HexCore
import SwiftUI

/// Dictation box content (plan 5.8): header, format toolbar, editor, footer.
struct DictationBoxView: View {
  @Bindable var store: StoreOf<DictationBoxFeature>
  let transcription: StoreOf<TranscriptionFeature>

  var body: some View {
    DictationBoxContent(store: store, transcription: transcription)
      .flowThemed(store.hexSettings.appearance)
  }
}

private struct DictationBoxContent: View {
  @Bindable var store: StoreOf<DictationBoxFeature>
  let transcription: StoreOf<TranscriptionFeature>
  @Environment(\.flowTheme) private var theme

  var body: some View {
    VStack(spacing: 8) {
      header
      if store.phase == .learning {
        learnView
      } else {
        if store.isCommandMode {
          commandBar
        }
        toolbar
        if store.isShowingDiff {
          diffPanel
        }
        BoxTextEditor(store: store)
          .padding(4)
          .flowPanel()
          .padding(.horizontal, 10)
          .overlay(alignment: .topLeading) {
            if store.text.length == 0 {
              Text(placeholder)
                .font(Font(store.baseFont))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 33)
                .padding(.vertical, 16)
                .allowsHitTesting(false)
            }
          }
        footer
      }
    }
    .padding(.top, 30)
    .frame(minWidth: 480, minHeight: 260)
    .background(FlowBackdrop(variant: store.mode == .literal ? 1 : 0))
    .confirmationDialog(
      "Discard dictation?",
      isPresented: $store.isConfirmingDiscard,
      titleVisibility: .visible
    ) {
      Button("Discard", role: .destructive) { store.send(.discardConfirmed) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("\(store.wordCount) words will be lost.")
    }
  }

  private var placeholder: String {
    if transcription.isRecording { return "Speak …" }
    if transcription.isTranscribing { return "Transcribing …" }
    return "Press the dictation key and speak. Commands like “new paragraph” or “period” work here."
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      Label(store.mode == .literal ? "Literal" : "Normal", systemImage: store.mode == .literal ? "paragraphsign" : "waveform")
        .flowFont(.callout, weight: .semibold)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.accent.opacity(0.14), in: Capsule())
      Text(modelName)
        .flowFont(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Menu {
        Button("Automatic") { store.send(.setLanguage(nil)) }
        Button("German") { store.send(.setLanguage("de")) }
        Button("English") { store.send(.setLanguage("en")) }
      } label: {
        Text(store.language.uppercased()).flowFont(.callout, monospaced: true)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Language of this box")
      Spacer()
      statusIndicator
    }
    .padding(.horizontal, 16)
  }

  private var modelName: String {
    let model = transcription.hexSettings.model(for: store.mode)
    return (try? LocalASRModelCatalog.descriptor(named: model))?.displayName ?? model
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if transcription.isRecording {
      HStack(spacing: 6) {
        Circle().fill(theme.accent).frame(width: 8, height: 8).shadow(color: theme.accent.opacity(0.6), radius: 3)
        LevelBars(level: transcription.meter.averagePower)
        if let start = transcription.recordingStartTime {
          TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Duration.seconds(context.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
              .flowFont(.callout, monospacedDigit: true)
          }
        }
      }
      .accessibilityLabel("Recording")
    } else if transcription.isTranscribing {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Transcribing").flowFont(.callout).foregroundStyle(.secondary)
      }
    } else if store.spellingMode {
      Label("Spell", systemImage: "character.cursor.ibeam")
        .flowFont(.callout)
        .foregroundStyle(.tint)
    }
  }

  // MARK: Command Mode

  /// Instruction for the selection: speak it with the dictation key or type it.
  private var commandBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "wand.and.stars").foregroundStyle(theme.accent)
      TextField("Say or type what to do – “shorter”, “as a list”, “in English” …", text: $store.instruction)
        .textFieldStyle(.plain)
        .onSubmit { store.send(.commandRun) }
      Button {
        store.send(.commandRun)
      } label: {
        Label("Run", systemImage: "return")
      }
      .buttonStyle(.flowPrimary)
      .disabled(store.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .padding(.leading, 14)
    .padding(.trailing, 6)
    .padding(.vertical, 5)
    .flowSurface(Capsule(), highlighted: true)
    .padding(.horizontal, 10)
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 6) {
      Menu {
        ForEach(BoxTextStyle.fontChoices, id: \.name) { choice in
          Button(choice.title) { store.send(.setFont(choice.name)) }
        }
      } label: {
        Text(BoxTextStyle.fontChoices.first { $0.name == store.hexSettings.boxFontName }?.title ?? store.hexSettings.boxFontName)
          .flowFont(.callout)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Font")

      Menu {
        ForEach([11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28], id: \.self) { size in
          Button("\(size) pt") { store.send(.setFontSize(Double(size))) }
        }
      } label: {
        Text("\(Int(store.hexSettings.boxFontSize)) pt").flowFont(.callout, monospacedDigit: true)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Font size")

      Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 16)

      toolButton("bold", "Bold") { store.send(.toggleBold) }
      toolButton("italic", "Italic") { store.send(.toggleItalic) }
      toolButton("textformat.size.larger", "Heading") { store.send(.toggleHeading) }
      toolButton("list.bullet", "Bullets") { store.send(.toggleBullets) }
      toolButton("quote.opening", "Wrap selection in quotes") { store.send(.quoteSelection) }
      toolButton("textformat", "Toggle case") { store.send(.cycleCase) }
      toolButton("character.cursor.ibeam", "Spelling mode: next dictation as letters", active: store.spellingMode) {
        store.send(.toggleSpellingMode)
      }
      if store.offersAI || store.isCommandMode {
        aiButton
      }

      Spacer()

      Picker("Format", selection: Binding(
        get: { store.hexSettings.boxOutputFormat },
        set: { store.send(.setFormat($0)) }
      )) {
        Text("Rich Text").tag(OutputFormat.richText)
        Text("Markdown").tag(OutputFormat.markdown)
        Text("Plain text").tag(OutputFormat.plainText)
      }
      .labelsHidden()
      .fixedSize()
      .help("What gets inserted")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .flowSurface(Capsule())
    .padding(.horizontal, 10)
    .controlSize(.small)
  }

  // MARK: AI

  /// ✨ runs the AI (menu picks the mode); after a run it turns into ⇄ (diff).
  @ViewBuilder
  private var aiButton: some View {
    switch store.aiPhase {
    case .idle:
      Menu {
        ForEach(store.hexSettings.postProcessing.allStyles) { style in
          Button {
            store.send(.aiTapped(style.id))
          } label: {
            Label(style.name, systemImage: style.symbol)
          }
        }
      } label: {
        Image(systemName: "sparkles")
      } primaryAction: {
        store.send(.aiTapped(store.targetSettings.postProcessing.boxStyleID))
      }
      .menuStyle(.button)
      .buttonStyle(.flowCompact)
      .fixedSize()
      .help("AI: \(store.targetSettings.postProcessing.boxStyle.name) (click) or choose a style")
      .accessibilityLabel("AI post-processing")
    case .running:
      Button {
        store.send(.aiCancelTapped)
      } label: {
        HStack(spacing: 4) {
          ProgressView().controlSize(.mini)
          Image(systemName: "xmark")
        }
        .frame(height: 16)
      }
      .buttonStyle(.flowCompact)
      .help("Cancel AI post-processing")
      .accessibilityLabel("Cancel AI post-processing")
    case .done:
      Button {
        store.send(.diffToggled)
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "arrow.left.arrow.right")
          if !store.aiIssues.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
        }
        .frame(height: 16)
      }
      .buttonStyle(FlowButtonStyle(kind: store.isShowingDiff ? .primary : .secondary, compact: true))
      .help("Show what the AI changed")
      .accessibilityLabel("Show AI changes")
    }
  }

  private var diffPanel: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView {
        Text(diffText)
          .flowFont(.callout)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 150)
      HStack(spacing: 10) {
        if let issue = store.aiIssues.first {
          Label(issue.explanation, systemImage: "exclamationmark.triangle.fill")
            .flowFont(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
        }
        Spacer()
        Button("Restore original") { store.send(.aiRevertTapped) }
          .buttonStyle(.flowCompact)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .flowSurface(RoundedRectangle(cornerRadius: FlowMetrics.panelRadius, style: .continuous), highlighted: true)
    .padding(.horizontal, 10)
  }

  private var diffText: AttributedString {
    var result = AttributedString()
    for segment in WordDiff.diff(store.aiOriginalText, store.aiResultText) {
      var part = AttributedString(segment.text + " ")
      switch segment.kind {
      case .same:
        part.foregroundColor = .secondary
      case .removed:
        part.foregroundColor = .red
        part.strikethroughStyle = .single
      case .added:
        part.foregroundColor = .green
        part.backgroundColor = .green.opacity(0.12)
      }
      result += part
    }
    return result
  }

  private func toolButton(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .flowFont(size: 12, weight: .medium)
        .frame(width: 26, height: 24)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.clear), in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 10) {
      Text(store.lastAction.isEmpty ? " " : store.lastAction)
        .flowFont(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Text("\(store.wordCount) words")
        .flowFont(.caption, monospacedDigit: true)
        .foregroundStyle(.tertiary)
      Button {
        store.send(.discardTapped)
      } label: {
        Image(systemName: "xmark")
          .flowFont(.body, weight: .semibold)
          .frame(width: 26, height: 20)
      }
      .buttonStyle(.flow)
      .help("Discard")
      .accessibilityLabel("Discard")

      Button {
        store.send(.confirmTapped)
      } label: {
        Image(systemName: "checkmark")
          .flowFont(.body, weight: .semibold)
          .frame(width: 34, height: 20)
      }
      .buttonStyle(.flowPrimary)
      .help(store.targetAppName.map { "Insert into \($0)" } ?? "Insert")
      .accessibilityLabel("Insert")
      .disabled(store.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
  }

  // MARK: Learning

  private var learnView: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(store.learnCandidates.count == 1 ? "Always replace?" : "Always replace these \(store.learnCandidates.count)?")
        .flowFont(.headline)
      Text("You corrected this by hand before. Ticked pairs are replaced from now on; unticked ones are not suggested again.")
        .flowFont(.caption)
        .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach($store.learnCandidates) { $candidate in
            Toggle(isOn: $candidate.isSelected) {
              HStack(spacing: 6) {
                Text(candidate.original.isEmpty ? "(neu)" : candidate.original).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").flowFont(.caption).foregroundStyle(.tertiary)
                Text(candidate.replacement).fontWeight(.medium)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Not now") { store.send(.learnSkipped) }
          .buttonStyle(.flow)
        Button("Add") { store.send(.learnConfirmed) }
          .buttonStyle(.flowPrimary)
          .disabled(!store.learnCandidates.contains(where: \.isSelected))
      }
    }
    .padding(16)
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

/// Five animated level bars (mint) for the recording indicator. The meter is
/// linear RMS (speech ≈ 0.01–0.1), so it is mapped logarithmically:
/// −55 dBFS → empty, −15 dBFS → full.
struct LevelBars: View {
  let level: Double

  static func normalized(_ level: Double) -> Double {
    let db = 20 * log10(max(level, 0.000_01))
    return min(max((db + 55) / 40, 0), 1)
  }

  var body: some View {
    let value = Self.normalized(level)
    HStack(spacing: 2) {
      ForEach(0 ..< 5, id: \.self) { index in
        // Middle bars react most, outer bars less – reads like a voice level.
        let weight = [0.55, 0.85, 1.0, 0.85, 0.55][index]
        let height = 4 + 12 * value * weight
        Capsule()
          .fill(value * weight > 0.08 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.3)))
          .frame(width: 3, height: height)
      }
    }
    .frame(height: 16)
    .animation(.easeOut(duration: 0.1), value: value)
  }
}
