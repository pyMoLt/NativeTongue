import HexCore
import SwiftUI

// MARK: - Colour field

/// Soft mesh-gradient colour field behind a whole window. Each `variant`
/// (page) moves the colour points a little; changing it lets the colours flow
/// into the new arrangement. Nothing animates while the variant stays the
/// same, so an open window costs no energy at rest.
struct FlowBackdrop: View {
  var variant: Int = 0
  @Environment(\.flowTheme) private var theme
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let dark = scheme == .dark
    let base = dark ? Color(red: 0.075, green: 0.075, blue: 0.10) : Color(red: 0.965, green: 0.965, blue: 0.985)
    let strength: Double = switch theme.background {
    case .vivid: dark ? 0.55 : 0.42
    case .subtle: dark ? 0.32 : 0.24
    case .off: 0
    }
    let layout = Self.layouts[abs(variant) % Self.layouts.count]
    let a = theme.accent.opacity(strength)
    let b = theme.companion.opacity(strength)
    let soft = theme.accent.opacity(strength * 0.45)
    let colors: [Color] = layout.colors.map { slot in
      switch slot {
      case 0: base
      case 1: a
      case 2: b
      default: soft
      }
    }
    MeshGradient(width: 3, height: 3, points: layout.points, colors: colors, background: base)
      .ignoresSafeArea()
      .animation(theme.animation(.smooth(duration: 1.1)), value: variant)
      .animation(theme.animation(.smooth(duration: 0.6)), value: theme)
      .accessibilityHidden(true)
  }

  private struct Layout {
    let points: [SIMD2<Float>]
    /// 0 = base, 1 = accent, 2 = companion, 3 = soft accent
    let colors: [Int]
  }

  private static let layouts: [Layout] = [
    Layout(points: [[0, 0], [0.55, 0], [1, 0], [0, 0.45], [0.40, 0.55], [1, 0.38], [0, 1], [0.62, 1], [1, 1]],
           colors: [1, 0, 2, 0, 3, 0, 2, 0, 1]),
    Layout(points: [[0, 0], [0.40, 0], [1, 0], [0, 0.60], [0.62, 0.42], [1, 0.55], [0, 1], [0.38, 1], [1, 1]],
           colors: [0, 2, 1, 3, 0, 0, 1, 0, 2]),
    Layout(points: [[0, 0], [0.60, 0], [1, 0], [0, 0.35], [0.50, 0.65], [1, 0.50], [0, 1], [0.55, 1], [1, 1]],
           colors: [2, 0, 0, 1, 0, 3, 0, 2, 1]),
    Layout(points: [[0, 0], [0.50, 0], [1, 0], [0, 0.52], [0.35, 0.40], [1, 0.62], [0, 1], [0.70, 1], [1, 1]],
           colors: [0, 1, 2, 0, 3, 0, 2, 1, 0]),
  ]
}

// MARK: - Glass surfaces

private struct FlowSurface<S: InsettableShape>: ViewModifier {
  let shape: S
  var interactive = false
  var highlighted = false
  @Environment(\.flowTheme) private var theme
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let dark = scheme == .dark
    let tint = highlighted ? theme.accent.opacity(dark ? 0.32 : 0.22) : nil
    let outline = contrast == .increased ? Color.primary.opacity(0.35) : Color.white.opacity(dark ? 0.08 : 0.45)
    switch theme.glass {
    case .clear:
      content
        .glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
    case .frosted:
      content
        .background((dark ? Color.white.opacity(0.05) : Color.white.opacity(0.52)), in: shape)
        .glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        .overlay(shape.strokeBorder(outline, lineWidth: 0.5))
    case .solid:
      content
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .background(tint ?? .clear, in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.08), lineWidth: 0.5))
    }
  }
}

extension View {
  /// The one surface of the Flow design: glass, frosted glass or solid,
  /// as chosen under Appearance.
  func flowSurface<S: InsettableShape>(_ shape: S, interactive: Bool = false, highlighted: Bool = false) -> some View {
    modifier(FlowSurface(shape: shape, interactive: interactive, highlighted: highlighted))
  }

  /// Pill-shaped surface (rows, fields, chips).
  func flowPill(highlighted: Bool = false) -> some View {
    flowSurface(RoundedRectangle(cornerRadius: FlowMetrics.pillRadius, style: .continuous), highlighted: highlighted)
  }

  /// Large surface for lists, editors and tables.
  func flowPanel() -> some View {
    flowSurface(RoundedRectangle(cornerRadius: FlowMetrics.panelRadius, style: .continuous))
  }
}

enum FlowMetrics {
  static let pillRadius: CGFloat = 22
  static let panelRadius: CGFloat = 24
  static let contentWidth: CGFloat = 700
  static let pagePadding: CGFloat = 28
  static let groupSpacing: CGFloat = 22
  static let pillSpacing: CGFloat = 6
  static let rowMinHeight: CGFloat = 44
  static let rowInsets = EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 12)
}
