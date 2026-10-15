import ComposableArchitecture
import HexCore
import SwiftUI

/// Appearance (2.6): accent colour, glass strength, colour field, motion.
struct AppearancePageView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @Environment(\.flowTheme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var appearance: AppearanceSettings { store.hexSettings.appearance }

  private func binding<Value>(_ keyPath: WritableKeyPath<AppearanceSettings, Value>) -> Binding<Value> {
    Binding(
      get: { store.hexSettings.appearance[keyPath: keyPath] },
      set: { value in store.$hexSettings.withLock { $0.appearance[keyPath: keyPath] = value } }
    )
  }

  var body: some View {
    FlowPage("Appearance", subtitle: "Light or dark, text size, accent colour, glass and motion for every NativeTongue window", symbol: "paintpalette") {
      preview

      FlowGroup("Display") {
        FlowSegmented(selection: binding(\.colorScheme), options: [
          FlowOption(AppearanceColorScheme.system, "System", systemImage: "circle.lefthalf.filled"),
          FlowOption(.light, "Light", systemImage: "sun.max"),
          FlowOption(.dark, "Dark", systemImage: "moon"),
        ])
        .flowRow("Appearance", caption: "System follows the light or dark setting of your Mac.")
        FlowSegmented(selection: binding(\.textSize), options: AppearanceTextSize.allCases.map { FlowOption($0, $0.displayName) }, compact: true)
          .flowRow("Text size", caption: appearance.textSize == .system
            ? "Follows macOS (System Settings → Accessibility → Display → Text size). Icons and rows grow with the text."
            : "A fixed size for NativeTongue. Icons and rows grow with the text.")
      }

      FlowGroup("Accent colour", footer: "Used for selections, switches, the menu bar panel, the dictation box and the recording pill.") {
        FlowBlock(padding: 14) {
          HStack(spacing: 10) {
            ForEach(AppearanceAccent.allCases, id: \.self) { accent in
              swatch(accent)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      FlowGroup("Surfaces", footer: reduceTransparency ? "“Reduce transparency” is on in System Settings, so all surfaces are solid." : nil) {
        FlowSegmented(selection: binding(\.glass), options: AppearanceGlass.allCases.map { FlowOption($0, $0.displayName) })
          .flowRow("Glass", caption: glassCaption)
        FlowSegmented(selection: binding(\.background), options: AppearanceBackground.allCases.map { FlowOption($0, $0.displayName) })
          .flowRow("Colour field", caption: "The soft colours behind the windows.")
      }

      FlowGroup("Motion", footer: reduceMotion ? "“Reduce motion” is on in System Settings, so transitions are reduced." : nil) {
        FlowSegmented(selection: binding(\.motion), options: AppearanceMotion.allCases.map { FlowOption($0, $0.displayName) })
          .flowRow("Transitions", caption: "Colours and selections flow into each other. Nothing moves while you are not interacting.")
      }

      dictationBoxGroup
    }
  }

  // MARK: Dictation Box

  private var box: DictationBoxAppearance { appearance.dictationBox }

  private var dictationBoxGroup: some View {
    FlowGroup("Dictation Box", footer: "Every style has the same functions; what a style does not show sits in the “…” menu. When the box opens: Dictation Box page.") {
      DictationBoxStylePreview(look: box, accent: box.followsApp ? theme.accent : FlowTheme.colors(for: box.accent).accent)
      FlowSegmented(selection: binding(\.dictationBox.style), options: [
        FlowOption(DictationBoxStyle.standard, "Standard", systemImage: "rectangle.split.3x1"),
        FlowOption(.compact, "Compact", systemImage: "rectangle.compress.vertical"),
        FlowOption(.minimal, "Minimal", systemImage: "rectangle"),
      ])
      .flowRow("Style", caption: styleCaption)
      FlowRow("Size", caption: "Scales the box's text and controls, on top of the text size above.") {
        HStack(spacing: 10) {
          Slider(value: Binding(
            get: { box.clampedScale },
            set: { value in binding(\.dictationBox.scale).wrappedValue = (value * 20).rounded() / 20 }
          ), in: 0.8 ... 1.5)
          .frame(width: 180)
          Text("\(Int((box.clampedScale * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
      }
      FlowRow("Opacity in the background", caption: "While you work in another app. The box is fully visible as soon as you click into it.") {
        HStack(spacing: 10) {
          Slider(value: Binding(
            get: { box.clampedInactiveOpacity },
            set: { value in binding(\.dictationBox.inactiveOpacity).wrappedValue = (value * 20).rounded() / 20 }
          ), in: 0.3 ... 1)
          .frame(width: 180)
          Text("\(Int((box.clampedInactiveOpacity * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
      }
      Toggle(isOn: Binding(
        get: { !box.followsApp },
        set: { own in binding(\.dictationBox.followsApp).wrappedValue = !own }
      )) {
        FlowLabel("Own look", caption: box.followsApp
          ? "Off: the box looks like the rest of NativeTongue."
          : "The box keeps its own light or dark mode, accent, glass and colour field – for example plain white or black next to a colourful app.")
      }
      if !box.followsApp {
        FlowSegmented(selection: binding(\.dictationBox.colorScheme), options: [
          FlowOption(AppearanceColorScheme.system, "System", systemImage: "circle.lefthalf.filled"),
          FlowOption(.light, "Light", systemImage: "sun.max"),
          FlowOption(.dark, "Dark", systemImage: "moon"),
        ])
        .flowRow("Box mode", caption: "System follows macOS, independent of the app setting above.")
        Picker("Accent", selection: binding(\.dictationBox.accent)) {
          ForEach(AppearanceAccent.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .flowRow("Box accent")
        FlowSegmented(selection: binding(\.dictationBox.glass), options: AppearanceGlass.allCases.map { FlowOption($0, $0.displayName) })
          .flowRow("Box glass", caption: "Solid gives a calm, opaque box.")
        FlowSegmented(selection: binding(\.dictationBox.background), options: AppearanceBackground.allCases.map { FlowOption($0, $0.displayName) })
          .flowRow("Box colour field", caption: "Off: a plain white or black surface.")
      }
      if box.style == .minimal {
        colorRow("Background", \.dictationBox.minimalBackground, fallback: .textBackgroundColor)
        colorRow("Text", \.dictationBox.minimalText, fallback: .textColor)
      }
    }
  }

  private var styleCaption: String {
    switch box.style {
    case .standard: "Header, formatting toolbar, text and footer – everything at a glance."
    case .compact: "One row with ✓, ✕, ✨ and “…”; formatting is in the menu. Smaller and calmer."
    case .minimal: "Just your text on a plain surface. Controls appear when you point at the box or once there is text."
    }
  }

  /// Own colour for the Minimal style, or the theme's colour ("Theme").
  private func colorRow(_ title: String, _ keyPath: WritableKeyPath<AppearanceSettings, String>, fallback: NSColor) -> some View {
    let value = binding(keyPath)
    return FlowRow(title, caption: value.wrappedValue.isEmpty ? "Follows light or dark mode." : value.wrappedValue) {
      HStack(spacing: 8) {
        if !value.wrappedValue.isEmpty {
          Button("Theme") { value.wrappedValue = "" }
            .buttonStyle(.flow)
        }
        ColorPicker("", selection: Binding(
          get: { Color(nsColor: NSColor(boxHex: value.wrappedValue) ?? fallback) },
          set: { color in value.wrappedValue = NSColor(color).boxHex }
        ), supportsOpacity: false)
        .labelsHidden()
      }
    }
  }

  private var glassCaption: String {
    switch appearance.glass {
    case .clear: "Liquid Glass as macOS draws it; most transparent."
    case .frosted: "Milky glass: calm and easy to read."
    case .solid: "Opaque surfaces without transparency."
    }
  }

  private func swatch(_ accent: AppearanceAccent) -> some View {
    let colors = FlowTheme.colors(for: accent)
    let selected = appearance.accent == accent
    return Button {
      withAnimation(theme.animation()) { binding(\.accent).wrappedValue = accent }
    } label: {
      VStack(spacing: 5) {
        Circle()
          .fill(LinearGradient(colors: [colors.accent, colors.companion], startPoint: .topLeading, endPoint: .bottomTrailing))
          .frame(width: 34, height: 34)
          .overlay {
            if selected {
              Image(systemName: "checkmark").flowFont(size: 13, weight: .bold).foregroundStyle(.white)
            }
          }
          .padding(3)
          .overlay(Circle().strokeBorder(selected ? colors.accent : .clear, lineWidth: 2))
        Text(accent.displayName).flowFont(.caption2).foregroundStyle(selected ? .primary : .secondary)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(accent.displayName) accent")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// Live preview of the current choice.
  private var preview: some View {
    FlowGroup("Preview") {
      ModeSwitch(mode: .normal) { _ in }
        .allowsHitTesting(false)
      Toggle(isOn: .constant(true)) { FlowLabel("A setting", caption: "Every setting is a pill: text left, control right.") }
        .allowsHitTesting(false)
    }
    .accessibilityHidden(true)
  }
}

/// Schematic preview of the dictation box style (not interactive).
private struct DictationBoxStylePreview: View {
  let look: DictationBoxAppearance
  let accent: Color

  var body: some View {
    let colors = MinimalBoxColors(look)
    FlowBlock(padding: 14) {
      HStack {
        Spacer(minLength: 0)
        VStack(alignment: .leading, spacing: 6) {
          switch look.style {
          case .standard:
            HStack(spacing: 6) {
              pill("Literal")
              Text("Whisper Turbo").font(.caption2).foregroundStyle(.secondary)
              Spacer()
            }
            HStack(spacing: 5) {
              ForEach(["bold", "italic", "textformat.size.larger", "list.bullet", "quote.opening", "sparkles"], id: \.self) { symbol in
                Image(systemName: symbol).font(.caption2)
              }
              Spacer()
              Text("Rich Text").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            sampleText.padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            HStack { Text("12 words").font(.caption2).foregroundStyle(.tertiary); Spacer(); buttons }
          case .compact:
            HStack(spacing: 6) {
              Image(systemName: "paragraphsign").font(.caption2).foregroundStyle(accent)
              Text("DE").font(.caption2.monospaced())
              Spacer()
              Image(systemName: "sparkles").font(.caption2)
              Image(systemName: "ellipsis.circle").font(.caption2)
              buttons
            }
            sampleText.padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
          case .minimal:
            HStack(spacing: 6) {
              Circle().fill(accent).frame(width: 6, height: 6)
              Spacer()
              Image(systemName: "ellipsis.circle").font(.caption2)
              buttons
            }
            sampleText
              .foregroundStyle(colors.text.map { Color(nsColor: $0) } ?? Color.primary)
          }
        }
        .padding(10)
        .frame(width: look.style == .standard ? 300 : look.style == .compact ? 250 : 220)
        .background(previewBackground(colors), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .modifier(PreviewScheme(scheme: (look.style == .minimal ? colors.scheme : nil) ?? ownScheme))
        .scaleEffect(look.clampedScale, anchor: .center)
        .frame(height: 150 * max(1, look.clampedScale))
        Spacer(minLength: 0)
      }
    }
    .accessibilityHidden(true)
  }

  /// Own light/dark mode of the box (own look), as the preview's colour scheme.
  private var ownScheme: ColorScheme? {
    switch look.ownColorScheme {
    case .light: .light
    case .dark: .dark
    case .system: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    case nil: nil
    }
  }

  private var sampleText: some View {
    Text("Befund unauffällig. Kontrolle in drei Monaten.").font(.caption)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var buttons: some View {
    HStack(spacing: 4) {
      Image(systemName: "xmark").font(.caption2.weight(.semibold))
      Image(systemName: "checkmark").font(.caption2.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2).background(accent, in: Capsule())
    }
  }

  private func pill(_ text: String) -> some View {
    Text(text).font(.caption2.weight(.semibold)).foregroundStyle(accent)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(accent.opacity(0.14), in: Capsule())
  }

  private func previewBackground(_ colors: MinimalBoxColors) -> AnyShapeStyle {
    if look.style == .minimal || (!look.followsApp && look.glass == .solid) {
      return AnyShapeStyle(colors.background ?? Color(nsColor: .textBackgroundColor))
    }
    return AnyShapeStyle(.regularMaterial)
  }
}

/// Light or dark preview only for a Minimal box with its own background colour.
private struct PreviewScheme: ViewModifier {
  let scheme: ColorScheme?

  func body(content: Content) -> some View {
    if let scheme { content.environment(\.colorScheme, scheme) } else { content }
  }
}
