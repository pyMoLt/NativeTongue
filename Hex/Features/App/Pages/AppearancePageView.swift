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
