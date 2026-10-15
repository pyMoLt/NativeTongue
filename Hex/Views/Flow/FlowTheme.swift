import AppKit
import HexCore
import SwiftUI

/// Resolved look of the "Flow" design (2.6) for one window: accent and
/// companion colour, glass strength, colour field and motion. Built from
/// `AppearanceSettings`; the system's "Reduce transparency" and "Reduce
/// motion" always win.
struct FlowTheme: Equatable {
  var accent: Color
  var companion: Color
  var glass: AppearanceGlass
  var background: AppearanceBackground
  var motion: AppearanceMotion
  /// Text size: 1 = macOS default; icons and rows grow with it.
  var textScale: CGFloat = 1

  static let standard = FlowTheme(settings: AppearanceSettings(), reduceTransparency: false, reduceMotion: false)

  init(settings: AppearanceSettings, reduceTransparency: Bool, reduceMotion: Bool, systemTextScale: CGFloat = 1) {
    let colors = Self.colors(for: settings.accent)
    accent = colors.accent
    companion = colors.companion
    glass = reduceTransparency ? .solid : settings.glass
    background = settings.background
    motion = reduceMotion ? .reduced : settings.motion
    textScale = settings.textSize == .system ? systemTextScale : CGFloat(settings.textSize.fixedScale)
  }

  /// Native controls follow the text size in steps.
  var controlSize: ControlSize {
    textScale < 0.95 ? .small : textScale > 1.18 ? .large : .regular
  }

  /// Animation for state changes (selection pills, mode pills, page colours).
  func animation(_ base: Animation = .smooth(duration: 0.35)) -> Animation? {
    motion == .fluid ? base : nil
  }

  static func colors(for accent: AppearanceAccent) -> (accent: Color, companion: Color) {
    switch accent {
    case .system:
      (Color(nsColor: .controlAccentColor), Color(nsColor: .controlAccentColor).opacity(0.75))
    case .violet:
      (Color(red: 0.49, green: 0.36, blue: 0.96), Color(red: 0.20, green: 0.60, blue: 0.96))
    case .indigo:
      (Color(red: 0.32, green: 0.36, blue: 0.93), Color(red: 0.64, green: 0.42, blue: 0.96))
    case .ocean:
      (Color(red: 0.10, green: 0.52, blue: 0.95), Color(red: 0.14, green: 0.76, blue: 0.80))
    case .teal:
      (Color(red: 0.10, green: 0.64, blue: 0.58), Color(red: 0.22, green: 0.55, blue: 0.95))
    case .coral:
      (Color(red: 0.95, green: 0.45, blue: 0.33), Color(red: 0.93, green: 0.36, blue: 0.62))
    case .rose:
      (Color(red: 0.90, green: 0.30, blue: 0.54), Color(red: 0.58, green: 0.40, blue: 0.96))
    case .graphite:
      (Color(red: 0.40, green: 0.42, blue: 0.48), Color(red: 0.56, green: 0.60, blue: 0.68))
    }
  }
}

private struct FlowThemeKey: EnvironmentKey {
  static let defaultValue = FlowTheme.standard
}

extension EnvironmentValues {
  var flowTheme: FlowTheme {
    get { self[FlowThemeKey.self] }
    set { self[FlowThemeKey.self] = newValue }
  }
}

/// Applies the user's appearance to a window's root view: theme in the
/// environment and the accent as tint for all system controls.
private struct FlowThemed: ViewModifier {
  let settings: AppearanceSettings
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var systemTextScale = SystemTextSize.scale

  func body(content: Content) -> some View {
    let theme = FlowTheme(settings: settings, reduceTransparency: reduceTransparency, reduceMotion: reduceMotion, systemTextScale: systemTextScale)
    content
      // Base font for text without its own style (row titles, labels), so it
      // scales with the text size like everything set via `flowFont`.
      .modifier(FlowFontModifier(style: .body, size: nil, weight: nil, design: .default, monospacedDigit: false, monospaced: false))
      .environment(\.flowTheme, theme)
      .controlSize(theme.controlSize)
      .tint(theme.accent)
      // macOS has no notification for its text size; re-read when the app becomes active.
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        let scale = SystemTextSize.scale
        if scale != systemTextScale { systemTextScale = scale }
      }
      .onAppear { FlowAppearance.apply(settings.colorScheme) }
      .onChange(of: settings.colorScheme) { _, scheme in FlowAppearance.apply(scheme) }
  }
}

extension View {
  func flowThemed(_ settings: AppearanceSettings) -> some View {
    modifier(FlowThemed(settings: settings))
  }
}

/// Light / dark / system for every window of the app (menu bar panel,
/// main window, dictation box, recording pill).
@MainActor
enum FlowAppearance {

  static func apply(_ scheme: AppearanceColorScheme) {
    let appearance: NSAppearance? = switch scheme {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
    if NSApp.appearance != appearance { NSApp.appearance = appearance }
  }
}

/// The text size chosen in macOS (System Settings → Accessibility → Display
/// → Text size), read from the accessibility preferences.
enum SystemTextSize {
  static var scale: CGFloat {
    let defaults = UserDefaults(suiteName: "com.apple.universalaccess")
    let categories = defaults?.dictionary(forKey: "FontSizeCategory")
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    // A per-app choice wins over the global one ("UseGlobal" = follow global).
    let perApp = categories?[bundleID] as? String
    let code = perApp.flatMap { $0 == "UseGlobal" ? nil : $0 } ?? categories?["global"] as? String
    return CGFloat(AppearanceTextSize.scale(forSystemCategory: code))
  }
}

/// macOS sizes of the text styles at the default text size.
enum FlowTextStyle {
  static func baseSize(_ style: Font.TextStyle) -> CGFloat {
    switch style {
    case .largeTitle: 26
    case .title: 22
    case .title2: 17
    case .title3: 15
    case .headline: 13
    case .body: 13
    case .callout: 12
    case .subheadline: 11
    case .footnote: 10
    case .caption: 10
    case .caption2: 10
    @unknown default: 13
    }
  }

  static func defaultWeight(_ style: Font.TextStyle) -> Font.Weight {
    style == .headline ? .semibold : .regular
  }
}

private struct FlowFontModifier: ViewModifier {
  var style: Font.TextStyle?
  var size: CGFloat?
  var weight: Font.Weight?
  var design: Font.Design
  var monospacedDigit: Bool
  var monospaced: Bool
  @Environment(\.flowTheme) private var theme

  func body(content: Content) -> some View {
    let base = size ?? style.map(FlowTextStyle.baseSize) ?? 13
    let resolvedWeight = weight ?? style.map(FlowTextStyle.defaultWeight) ?? .regular
    var font = Font.system(size: (base * theme.textScale).rounded(), weight: resolvedWeight, design: monospaced ? .monospaced : design)
    if monospacedDigit { font = font.monospacedDigit() }
    return content.font(font)
  }
}

extension View {
  /// A text style that follows the app's text size (Appearance).
  func flowFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default, monospacedDigit: Bool = false, monospaced: Bool = false) -> some View {
    modifier(FlowFontModifier(style: style, size: nil, weight: weight, design: design, monospacedDigit: monospacedDigit, monospaced: monospaced))
  }

  /// A point size (at the default text size) that follows the app's text size.
  func flowFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, monospacedDigit: Bool = false) -> some View {
    modifier(FlowFontModifier(style: nil, size: size, weight: weight, design: design, monospacedDigit: monospacedDigit, monospaced: false))
  }
}
