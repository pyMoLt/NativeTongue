import ComposableArchitecture
import HexCore
import SwiftUI

/// Dictation box content (plan 5.8): header, format toolbar, editor, footer.
struct DictationBoxView: View {
  @Bindable var store: StoreOf<DictationBoxFeature>
  let transcription: StoreOf<TranscriptionFeature>

  var body: some View {
    VStack(spacing: 0) {
      header
      if store.phase == .learning {
        learnView
      } else {
        toolbar
        if store.isShowingDiff {
          diffPanel
        }
        BoxTextEditor(store: store)
          .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
          .overlay(alignment: .topLeading) {
            if store.text.length == 0 {
              Text(placeholder)
                .font(Font(store.baseFont))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 19)
                .padding(.vertical, 12)
                .allowsHitTesting(false)
            }
          }
        footer
      }
    }
    .frame(minWidth: 480, minHeight: 260)
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
        .font(.callout.weight(.semibold))
        .labelStyle(.titleAndIcon)
      Text("·").foregroundStyle(.tertiary)
      Text(modelName)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Menu {
        Button("Automatic") { store.send(.setLanguage(nil)) }
        Button("German") { store.send(.setLanguage("de")) }
        Button("English") { store.send(.setLanguage("en")) }
      } label: {
        Text(store.language.uppercased()).font(.callout.monospaced())
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Language of this box")
      Spacer()
      statusIndicator
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .glassEffect(.regular, in: .rect(cornerRadius: 0))
  }

  private var modelName: String {
    let model = transcription.hexSettings.model(for: store.mode)
    return (try? LocalASRModelCatalog.descriptor(named: model))?.displayName ?? model
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if transcription.isRecording {
      HStack(spacing: 6) {
        Circle().fill(.red).frame(width: 8, height: 8)
        LevelBars(level: transcription.meter.averagePower)
        if let start = transcription.recordingStartTime {
          TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Duration.seconds(context.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
              .font(.callout.monospacedDigit())
          }
        }
      }
      .accessibilityLabel("Recording")
    } else if transcription.isTranscribing {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Transcribing").font(.callout).foregroundStyle(.secondary)
      }
    } else if store.spellingMode {
      Label("Spell", systemImage: "character.cursor.ibeam")
        .font(.callout)
        .foregroundStyle(.tint)
    }
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
          .font(.callout)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Font")

      Menu {
        ForEach([11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28], id: \.self) { size in
          Button("\(size) pt") { store.send(.setFontSize(Double(size))) }
        }
      } label: {
        Text("\(Int(store.hexSettings.boxFontSize)) pt").font(.callout.monospacedDigit())
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Font size")

      Divider().frame(height: 18)

      toolButton("bold", "Bold") { store.send(.toggleBold) }
      toolButton("italic", "Italic") { store.send(.toggleItalic) }
      toolButton("textformat.size.larger", "Heading") { store.send(.toggleHeading) }
      toolButton("list.bullet", "Bullets") { store.send(.toggleBullets) }
      toolButton("quote.opening", "Wrap selection in quotes") { store.send(.quoteSelection) }
      toolButton("textformat", "Toggle case") { store.send(.cycleCase) }
      toolButton("character.cursor.ibeam", "Spelling mode: next dictation as letters", active: store.spellingMode) {
        store.send(.toggleSpellingMode)
      }
      if store.offersAI {
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
    .padding(.vertical, 6)
    .controlSize(.small)
  }

  // MARK: AI

  /// ✨ runs the AI (menu picks the mode); after a run it turns into ⇄ (diff).
  @ViewBuilder
  private var aiButton: some View {
    switch store.aiPhase {
    case .idle:
      Menu {
        ForEach(PolishMode.allCases, id: \.self) { mode in
          Button(mode.displayName) { store.send(.aiTapped(mode)) }
        }
      } label: {
        Image(systemName: "sparkles")
      } primaryAction: {
        store.send(.aiTapped(store.hexSettings.postProcessing.boxDefaultMode))
      }
      .menuStyle(.button)
      .buttonStyle(.glass)
      .fixedSize()
      .help("AI post-processing: \(store.hexSettings.postProcessing.boxDefaultMode.displayName) (click) or choose a mode")
      .accessibilityLabel("AI post-processing")
    case .running:
      Button {
        store.send(.aiCancelTapped)
      } label: {
        HStack(spacing: 4) {
          ProgressView().controlSize(.mini)
          Image(systemName: "xmark")
        }
        .frame(height: 20)
      }
      .buttonStyle(.glass)
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
        .frame(height: 20)
      }
      .buttonStyle(.glass)
      .tint(store.isShowingDiff ? .accentColor : nil)
      .help("Show what the AI changed")
      .accessibilityLabel("Show AI changes")
    }
  }

  private var diffPanel: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView {
        Text(diffText)
          .font(.callout)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 150)
      HStack(spacing: 10) {
        if let issue = store.aiIssues.first {
          Label(issue.explanation, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
        }
        Spacer()
        Button("Restore original") { store.send(.aiRevertTapped) }
          .buttonStyle(.glass)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Color.accentColor.opacity(0.06))
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
        .frame(width: 22, height: 20)
    }
    .buttonStyle(.glass)
    .tint(active ? .accentColor : nil)
    .help(help)
    .accessibilityLabel(help)
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 10) {
      Text(store.lastAction.isEmpty ? " " : store.lastAction)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Text("\(store.wordCount) words")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
      Button {
        store.send(.discardTapped)
      } label: {
        Image(systemName: "xmark")
          .font(.body.weight(.semibold))
          .frame(width: 30, height: 22)
      }
      .buttonStyle(.glass)
      .help("Discard")
      .accessibilityLabel("Discard")

      Button {
        store.send(.confirmTapped)
      } label: {
        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .frame(width: 30, height: 22)
      }
      .buttonStyle(.glassProminent)
      .help(store.targetAppName.map { "Insert into \($0)" } ?? "Insert")
      .accessibilityLabel("Insert")
      .disabled(store.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  // MARK: Learning

  private var learnView: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Add \(store.learnCandidates.count) correction\(store.learnCandidates.count == 1 ? "" : "s") to your vocabulary?")
        .font(.headline)
      Text("From now on the variant on the left is replaced by the spelling on the right.")
        .font(.caption)
        .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach($store.learnCandidates) { $candidate in
            Toggle(isOn: $candidate.isSelected) {
              HStack(spacing: 6) {
                Text(candidate.original.isEmpty ? "(neu)" : candidate.original).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
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
          .buttonStyle(.glass)
        Button("Add") { store.send(.learnConfirmed) }
          .buttonStyle(.glassProminent)
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
          .fill(value * weight > 0.08 ? Color.accentColor : Color.secondary.opacity(0.3))
          .frame(width: 3, height: height)
      }
    }
    .frame(height: 16)
    .animation(.easeOut(duration: 0.1), value: value)
  }
}
