import Foundation

/// Light, dark or follow the system.
public enum AppearanceColorScheme: String, Codable, CaseIterable, Equatable, Sendable {
	case system
	case light
	case dark

	public var displayName: String {
		switch self {
		case .system: "System"
		case .light: "Light"
		case .dark: "Dark"
		}
	}
}

/// Text size of the interface: follow macOS (Accessibility → Display →
/// Text size) or a fixed size. Icons and rows grow with the text.
public enum AppearanceTextSize: String, Codable, CaseIterable, Equatable, Sendable {
	case system
	case extraSmall
	case small
	case medium
	case large
	case extraLarge
	case xxLarge

	public var displayName: String {
		switch self {
		case .system: "System"
		case .extraSmall: "XS"
		case .small: "S"
		case .medium: "M"
		case .large: "L"
		case .extraLarge: "XL"
		case .xxLarge: "XXL"
		}
	}

	/// Scale for a fixed size; `system` uses `scale(forSystemCategory:)`.
	public var fixedScale: Double {
		switch self {
		case .system, .medium: 1.0
		case .extraSmall: 0.85
		case .small: 0.92
		case .large: 1.12
		case .extraLarge: 1.25
		case .xxLarge: 1.4
		}
	}

	/// macOS stores its text size as a category code ("XS" … "XXXL", "AX1" …).
	public static func scale(forSystemCategory code: String?) -> Double {
		switch code?.uppercased() {
		case "XS": 0.85
		case "S": 0.92
		case "L": 1.12
		case "XL": 1.25
		case "XXL": 1.4
		case "XXXL", "AX1", "AX2", "AX3", "AX4", "AX5": 1.5
		default: 1.0
		}
	}
}

/// Accent colour of the interface (2.6 "Flow" design).
public enum AppearanceAccent: String, Codable, CaseIterable, Equatable, Sendable {
	case system
	case violet
	case indigo
	case ocean
	case teal
	case coral
	case rose
	case graphite

	public var displayName: String {
		switch self {
		case .system: "System"
		case .violet: "Violet"
		case .indigo: "Indigo"
		case .ocean: "Ocean"
		case .teal: "Teal"
		case .coral: "Coral"
		case .rose: "Rose"
		case .graphite: "Graphite"
		}
	}
}

/// How strongly surfaces show what lies behind them.
public enum AppearanceGlass: String, Codable, CaseIterable, Equatable, Sendable {
	/// Liquid Glass as macOS draws it.
	case clear
	/// Milky glass: more opaque, easier to read.
	case frosted
	/// Opaque surfaces, no transparency.
	case solid

	public var displayName: String {
		switch self {
		case .clear: "Clear"
		case .frosted: "Frosted"
		case .solid: "Solid"
		}
	}
}

/// Colour field behind the windows.
public enum AppearanceBackground: String, Codable, CaseIterable, Equatable, Sendable {
	case vivid
	case subtle
	case off

	public var displayName: String {
		switch self {
		case .vivid: "Vivid"
		case .subtle: "Subtle"
		case .off: "Off"
		}
	}
}

/// Animated transitions (page changes, selection pills, mode pills).
public enum AppearanceMotion: String, Codable, CaseIterable, Equatable, Sendable {
	case fluid
	case reduced

	public var displayName: String {
		switch self {
		case .fluid: "Fluid"
		case .reduced: "Reduced"
		}
	}
}

/// Layout of the dictation box. Every style offers the same functions; less frequent
/// ones move into the "…" menu.
public enum DictationBoxStyle: String, Codable, CaseIterable, Equatable, Sendable {
	case standard
	case compact
	case minimal

	public var displayName: String {
		switch self {
		case .standard: "Standard"
		case .compact: "Compact"
		case .minimal: "Minimal"
		}
	}
}

/// Look of the dictation box (Settings → Appearance → Dictation Box).
public struct DictationBoxAppearance: Codable, Equatable, Sendable {
	public var style: DictationBoxStyle = .standard
	/// Scale of the box's text and controls, on top of the app's text size (0.8–1.5).
	public var scale: Double = 1
	/// Opacity while another app is active (0.3–1); the box is opaque while you work in it.
	public var inactiveOpacity: Double = 1
	/// Minimal style only: own colours as "#RRGGBB"; empty = follow the app theme.
	public var minimalBackground = ""
	public var minimalText = ""
	/// true: the box looks like the rest of the app. false: its own light/dark mode,
	/// accent, glass and colour field (a plain white or black box next to a vivid app).
	public var followsApp = true
	public var colorScheme: AppearanceColorScheme = .system
	public var accent: AppearanceAccent = .graphite
	public var glass: AppearanceGlass = .solid
	public var background: AppearanceBackground = .off

	public init() {}

	/// The appearance the box is drawn with. The app's light/dark choice stays (it is
	/// applied app-wide); the box's own one is set on its window (`ownColorScheme`).
	public func effective(app: AppearanceSettings) -> AppearanceSettings {
		guard !followsApp else { return app }
		var look = app
		look.accent = accent
		look.glass = glass
		look.background = background
		return look
	}

	/// Light / dark / system for the box window only; nil = like the app.
	public var ownColorScheme: AppearanceColorScheme? { followsApp ? nil : colorScheme }

	public var clampedScale: Double { min(max(scale, 0.8), 1.5) }
	public var clampedInactiveOpacity: Double { min(max(inactiveOpacity, 0.3), 1) }

	private enum CodingKeys: String, CodingKey {
		case style, scale, inactiveOpacity, minimalBackground, minimalText
		case followsApp, colorScheme, accent, glass, background
	}

	/// Missing or unknown values fall back to the defaults.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = DictationBoxAppearance()
		style = (try? c.decodeIfPresent(DictationBoxStyle.self, forKey: .style)) ?? d.style
		scale = (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? d.scale
		inactiveOpacity = (try? c.decodeIfPresent(Double.self, forKey: .inactiveOpacity)) ?? d.inactiveOpacity
		minimalBackground = (try? c.decodeIfPresent(String.self, forKey: .minimalBackground)) ?? d.minimalBackground
		minimalText = (try? c.decodeIfPresent(String.self, forKey: .minimalText)) ?? d.minimalText
		followsApp = (try? c.decodeIfPresent(Bool.self, forKey: .followsApp)) ?? d.followsApp
		colorScheme = (try? c.decodeIfPresent(AppearanceColorScheme.self, forKey: .colorScheme)) ?? d.colorScheme
		accent = (try? c.decodeIfPresent(AppearanceAccent.self, forKey: .accent)) ?? d.accent
		glass = (try? c.decodeIfPresent(AppearanceGlass.self, forKey: .glass)) ?? d.glass
		background = (try? c.decodeIfPresent(AppearanceBackground.self, forKey: .background)) ?? d.background
	}
}

/// Look of the app: accent colour, glass strength, background and motion.
public struct AppearanceSettings: Codable, Equatable, Sendable {
	public var colorScheme: AppearanceColorScheme = .system
	public var textSize: AppearanceTextSize = .system
	public var accent: AppearanceAccent = .violet
	public var glass: AppearanceGlass = .frosted
	public var background: AppearanceBackground = .subtle
	public var motion: AppearanceMotion = .fluid
	public var dictationBox = DictationBoxAppearance()

	public init(
		colorScheme: AppearanceColorScheme = .system,
		textSize: AppearanceTextSize = .system,
		accent: AppearanceAccent = .violet,
		glass: AppearanceGlass = .frosted,
		background: AppearanceBackground = .subtle,
		motion: AppearanceMotion = .fluid
	) {
		self.colorScheme = colorScheme
		self.textSize = textSize
		self.accent = accent
		self.glass = glass
		self.background = background
		self.motion = motion
	}

	private enum CodingKeys: String, CodingKey {
		case colorScheme, textSize, accent, glass, background, motion, dictationBox
	}

	/// Missing or unknown values fall back to the defaults.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = AppearanceSettings()
		colorScheme = (try? c.decodeIfPresent(AppearanceColorScheme.self, forKey: .colorScheme)) ?? d.colorScheme
		textSize = (try? c.decodeIfPresent(AppearanceTextSize.self, forKey: .textSize)) ?? d.textSize
		accent = (try? c.decodeIfPresent(AppearanceAccent.self, forKey: .accent)) ?? d.accent
		glass = (try? c.decodeIfPresent(AppearanceGlass.self, forKey: .glass)) ?? d.glass
		background = (try? c.decodeIfPresent(AppearanceBackground.self, forKey: .background)) ?? d.background
		motion = (try? c.decodeIfPresent(AppearanceMotion.self, forKey: .motion)) ?? d.motion
		dictationBox = (try? c.decodeIfPresent(DictationBoxAppearance.self, forKey: .dictationBox)) ?? d.dictationBox
	}
}
