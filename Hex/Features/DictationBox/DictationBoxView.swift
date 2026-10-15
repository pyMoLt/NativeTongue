import ComposableArchitecture
import HexCore
import SwiftUI

/// Dictation box content (plan 5.8). Three styles (3.2.2) with the same functions:
/// Standard (header, format toolbar, editor, footer), Compact (one control row,
/// formatting in "…") and Minimal (text on a plain surface, controls on hover).
struct DictationBoxView: View {
  @Bindable var store: StoreOf<DictationBoxFeature>
  let transcription: StoreOf<TranscriptionFeature>

  var body: some View {
    let appearance = store.hexSettings.appearance
    DictationBoxContent(store: store, transcription: transcription)
      .modifier(BoxScale(scale: appearance.dictationBox.clampedScale))
      .flowThemed(appearance.dictationBox.effective(app: appearance))
  }
}

/// The box's own scale on top of the app's text size (Appearance → Dictation Box).
private struct BoxScale: ViewModifier {
  let scale: Double
  @Environment(\.flowTheme) private var theme

  func body(content: Content) -> some View {
    var scaled = theme
    scaled.textScale *= scale
    return content
      .flowFont(.body)
      .environment(\.flowTheme, scaled)
      .controlSize(scaled.controlSize)
  }
}

/// Default and minimum sizes per style, before the box scale.
enum DictationBoxMetrics {
  static func defaultSize(_ style: DictationBoxStyle) -> CGSize {
    switch style {
    case .standard: CGSize(width: 640, height: 360)
    case .compact: CGSize(width: 520, height: 260)
    case .minimal: CGSize(width: 460, height: 200)
    }
  }

  static func minimumSize(_ style: DictationBoxStyle) -> CGSize {
    switch style {
    case .standard: CGSize(width: 440, height: 240)
    case .compact: CGSize(width: 360, height: 180)
    case .minimal: CGSize(width: 320, height: 130)
    }
  }
}

private struct DictationBoxContent: View {
  @Bindable var store: StoreOf<DictationBoxFeature>
  let transcription: StoreOf<TranscriptionFeature>
  @Environment(\.flowTheme) private var theme
  @State private var isHovering = false

  private var look: DictationBoxAppearance { store.hexSettings.appearance.dictationBox }

  var body: some View {
    let minimum = DictationBoxMetrics.minimumSize(look.style)
    Group {
      switch look.style {
      case .standard: standardLayout
      case .compact: compactLayout
      case .minimal: minimalLayout
      }
    }
    .frame(minWidth: minimum.width * look.clampedScale, minHeight: minimum.height * look.clampedScale)
    .onHover { isHovering = $0 }
    .onChange(of: look) { _, _ in
      NotificationCenter.default.post(name: .dictationBoxLookChanged, object: nil)
    }
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

  // MARK: Layouts

  private var standardLayout: some View {
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
        editor()
          .flowPanel()
          .padding(.horizontal, 10)
        footer
      }
    }
    .padding(.top, 30)
    .background(FlowBackdrop(variant: store.mode == .literal ? 1 : 0))
  }

  /// One control row; formatting, font and output format live in "…".
  private var compactLayout: some View {
    VStack(spacing: 6) {
      compactHeader
      if store.phase == .learning {
        learnView
      } else {
        if store.isCommandMode {
          commandBar
        }
        if store.isShowingDiff {
          diffPanel
        }
        editor()
          .flowPanel()
          .padding(.horizontal, 8)
        HStack(spacing: 8) {
          Text(store.lastAction.isEmpty ? " " : store.lastAction)
            .flowFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 4)
          Text("\(store.wordCount) words")
            .flowFont(.caption2, monospacedDigit: true)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
      }
    }
    .padding(.top, 26)
    .background(FlowBackdrop(variant: store.mode == .literal ? 1 : 0))
  }

  private var compactHeader: some View {
    HStack(spacing: 8) {
      Image(systemName: store.mode == .literal ? "paragraphsign" : "waveform")
        .flowFont(.callout, weight: .semibold)
        .foregroundStyle(theme.accent)
        .frame(width: 26, height: 22)
        .background(theme.accent.opacity(0.14), in: Capsule())
        .help(store.mode == .literal ? "Literal" : "Normal")
      languageMenu
      statusIndicator
      Spacer(minLength: 4)
      if store.offersAI || store.isCommandMode {
        aiButton
      }
      moreMenu(formatting: true, fonts: true, output: true, language: false, ai: false)
      actionButtons
    }
    .padding(.horizontal, 12)
  }

  /// Text on a plain surface; controls appear on hover or once there is text.
  private var minimalLayout: some View {
    let colors = MinimalBoxColors(look)
    return VStack(spacing: 4) {
      HStack(spacing: 8) {
        if transcription.isRecording {
          Circle().fill(theme.accent).frame(width: 8, height: 8).shadow(color: theme.accent.opacity(0.6), radius: 3)
            .accessibilityLabel("Recording")
        } else if transcription.isTranscribing {
          ProgressView().controlSize(.mini)
        } else if store.spellingMode {
          Image(systemName: "character.cursor.ibeam").foregroundStyle(.tint).help("Spelling mode")
        }
        Spacer(minLength: 4)
        if isHovering || store.text.length > 0 || store.isCommandMode || store.aiPhase != .idle {
          if store.aiPhase != .idle || store.isCommandMode {
            aiButton
          }
          moreMenu(formatting: true, fonts: true, output: true, language: true, ai: store.offersAI)
          actionButtons
        }
      }
      .frame(minHeight: 24)
      .padding(.horizontal, 12)
      if store.phase == .learning {
        learnView
      } else {
        if store.isCommandMode {
          commandBar
        }
        if store.isShowingDiff {
          diffPanel
        }
        editor(textColor: colors.text)
          .padding(.horizontal, 4)
          .padding(.bottom, 6)
      }
    }
    .padding(.top, 24)
    .background(colors.background ?? Color(nsColor: .textBackgroundColor))
    .modifier(SchemeOverride(scheme: colors.scheme))
  }

  /// The editor with its placeholder; `textColor` only in Minimal with an own colour.
  private func editor(textColor: NSColor? = nil) -> some View {
    BoxTextEditor(store: store, displayTextColor: textColor, scale: look.clampedScale)
      .padding(4)
      .overlay(alignment: .topLeading) {
        if store.text.length == 0 {
          Text(placeholder)
            .font(Font(store.baseFont))
            .foregroundStyle(.tertiary)
            // Editor padding + text container inset + line fragment padding.
            .padding(.horizontal, 23)
            .padding(.vertical, 16)
            .allowsHitTesting(false)
        }
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
      languageMenu
      Spacer()
      statusIndicator
    }
    .padding(.horizontal, 16)
  }

  private var languageMenu: some View {
    Menu {
      languageItems
    } label: {
      Text(store.language.uppercased()).flowFont(.callout, monospaced: true)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Language of this box")
  }

  @ViewBuilder
  private var languageItems: some View {
    Button("Automatic") { store.send(.setLanguage(nil)) }
    Button("German") { store.send(.setLanguage("de")) }
    Button("English") { store.send(.setLanguage("en")) }
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

  /// Full row when it fits; otherwise font, size and output format move into
  /// "…", and at the narrowest the formatting buttons too (nothing is clipped).
  private var toolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        fontMenus
        separator
        formattingButtons
        if store.offersAI || store.isCommandMode { aiButton }
        Spacer(minLength: 6)
        outputFormatPicker
      }
      HStack(spacing: 6) {
        formattingButtons
        if store.offersAI || store.isCommandMode { aiButton }
        Spacer(minLength: 6)
        moreMenu(formatting: false, fonts: true, output: true, language: false, ai: false)
      }
      HStack(spacing: 6) {
        toolButton("bold", "Bold") { store.send(.toggleBold) }
        toolButton("italic", "Italic") { store.send(.toggleItalic) }
        toolButton("list.bullet", "Bullets") { store.send(.toggleBullets) }
        if store.offersAI || store.isCommandMode { aiButton }
        Spacer(minLength: 6)
        moreMenu(formatting: true, fonts: true, output: true, language: false, ai: false)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .flowSurface(Capsule())
    .padding(.horizontal, 10)
    .controlSize(.small)
  }

  private var separator: some View {
    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 16)
  }

  @ViewBuilder
  private var fontMenus: some View {
    Menu {
      fontItems
    } label: {
      Text(fontTitle).flowFont(.callout)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Font")

    Menu {
      sizeItems
    } label: {
      Text("\(Int(store.hexSettings.boxFontSize)) pt").flowFont(.callout, monospacedDigit: true)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Font size")
  }

  private var fontTitle: String {
    BoxTextStyle.fontChoices.first { $0.name == store.hexSettings.boxFontName }?.title ?? store.hexSettings.boxFontName
  }

  @ViewBuilder
  private var fontItems: some View {
    ForEach(BoxTextStyle.fontChoices, id: \.name) { choice in
      Button(choice.title) { store.send(.setFont(choice.name)) }
    }
  }

  @ViewBuilder
  private var sizeItems: some View {
    ForEach([11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28], id: \.self) { size in
      Button("\(size) pt") { store.send(.setFontSize(Double(size))) }
    }
  }

  @ViewBuilder
  private var formattingButtons: some View {
    toolButton("bold", "Bold") { store.send(.toggleBold) }
    toolButton("italic", "Italic") { store.send(.toggleItalic) }
    toolButton("textformat.size.larger", "Heading") { store.send(.toggleHeading) }
    toolButton("list.bullet", "Bullets") { store.send(.toggleBullets) }
    toolButton("quote.opening", "Wrap selection in quotes") { store.send(.quoteSelection) }
    toolButton("textformat", "Toggle case") { store.send(.cycleCase) }
    toolButton("character.cursor.ibeam", "Spelling mode: next dictation as letters", active: store.spellingMode) {
      store.send(.toggleSpellingMode)
    }
  }

  private var outputFormatBinding: Binding<OutputFormat> {
    Binding(get: { store.hexSettings.boxOutputFormat }, set: { store.send(.setFormat($0)) })
  }

  private var outputFormatPicker: some View {
    Picker("Format", selection: outputFormatBinding) {
      outputFormatOptions
    }
    .labelsHidden()
    .fixedSize()
    .help("What gets inserted")
  }

  @ViewBuilder
  private var outputFormatOptions: some View {
    Text("Rich Text").tag(OutputFormat.richText)
    Text("Markdown").tag(OutputFormat.markdown)
    Text("Plain text").tag(OutputFormat.plainText)
  }

  /// Everything a style does not show directly; the same actions as the buttons.
  private func moreMenu(formatting: Bool, fonts: Bool, output: Bool, language: Bool, ai: Bool) -> some View {
    Menu {
      if language {
        Menu("Language") { languageItems }
      }
      if formatting {
        Section {
          Button("Bold") { store.send(.toggleBold) }
          Button("Italic") { store.send(.toggleItalic) }
          Button("Heading") { store.send(.toggleHeading) }
          Button("Bullets") { store.send(.toggleBullets) }
          Button("Wrap selection in quotes") { store.send(.quoteSelection) }
          Button("Toggle case") { store.send(.cycleCase) }
          Toggle("Spelling mode (next dictation as letters)", isOn: Binding(
            get: { store.spellingMode },
            set: { _ in store.send(.toggleSpellingMode) }
          ))
        }
      }
      if fonts {
        Section {
          Menu("Font: \(fontTitle)") { fontItems }
          Menu("Size: \(Int(store.hexSettings.boxFontSize)) pt") { sizeItems }
        }
      }
      if ai, store.aiPhase == .idle {
        Menu("AI") {
          ForEach(store.hexSettings.postProcessing.allStyles) { style in
            Button {
              store.send(.aiTapped(style.id))
            } label: {
              Label(style.name, systemImage: style.symbol)
            }
          }
        }
      }
      if output {
        Picker("Insert as", selection: outputFormatBinding) { outputFormatOptions }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More")
    .accessibilityLabel("More box functions")
  }

  /// ✕ and ✓ (footer in Standard, header row in Compact and Minimal).
  private var actionButtons: some View {
    HStack(spacing: 6) {
      Button {
        store.send(.discardTapped)
      } label: {
        Image(systemName: "xmark")
          .flowFont(.body, weight: .semibold)
          .frame(width: 22, height: 18)
      }
      .buttonStyle(.flow)
      .help("Discard")
      .accessibilityLabel("Discard")

      Button {
        store.send(.confirmTapped)
      } label: {
        Image(systemName: "checkmark")
          .flowFont(.body, weight: .semibold)
          .frame(width: 30, height: 18)
      }
      .buttonStyle(.flowPrimary)
      .help(store.targetAppName.map { "Insert into \($0)" } ?? "Insert")
      .accessibilityLabel("Insert")
      .disabled(store.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
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

/// Minimal style colours from Appearance → Dictation Box ("#RRGGBB"; empty = theme).
struct MinimalBoxColors {
  let background: Color?
  let text: NSColor?
  /// Light or dark controls to match an own background colour.
  let scheme: ColorScheme?

  init(_ look: DictationBoxAppearance) {
    let background = NSColor(boxHex: look.minimalBackground)
    self.background = background.map(Color.init(nsColor:))
    text = NSColor(boxHex: look.minimalText)
    scheme = background.map { $0.boxLuminance < 0.5 ? .dark : .light }
  }
}

extension NSColor {
  /// "#RRGGBB" → colour; nil for an empty or invalid value.
  convenience init?(boxHex: String) {
    var hex = boxHex.trimmingCharacters(in: .whitespaces)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    self.init(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }

  var boxHex: String {
    guard let rgb = usingColorSpace(.sRGB) else { return "" }
    return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
  }

  var boxLuminance: CGFloat {
    guard let rgb = usingColorSpace(.sRGB) else { return 1 }
    return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
  }
}

extension Notification.Name {
  /// Style, scale or opacity of the dictation box changed (panel size limits, opacity).
  static let dictationBoxLookChanged = Notification.Name("LocalASR.dictationBoxLookChanged")
}

/// Light or dark controls only when the Minimal style has its own background colour.
private struct SchemeOverride: ViewModifier {
  let scheme: ColorScheme?

  func body(content: Content) -> some View {
    if let scheme { content.environment(\.colorScheme, scheme) } else { content }
  }
}

extension AppearanceColorScheme {
  /// Window appearance for the box's own light/dark mode; `.system` reads macOS itself
  /// (the app may force its own mode on `NSApp`).
  @MainActor
  var boxWindowAppearance: NSAppearance? {
    switch self {
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    case .system:
      NSAppearance(named: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .darkAqua : .aqua)
    }
  }
}
