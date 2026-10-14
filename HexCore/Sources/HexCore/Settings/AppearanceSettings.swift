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

/// Look of the app: accent colour, glass strength, background and motion.
public struct AppearanceSettings: Codable, Equatable, Sendable {
	public var colorScheme: AppearanceColorScheme = .system
	public var textSize: AppearanceTextSize = .system
	public var accent: AppearanceAccent = .violet
	public var glass: AppearanceGlass = .frosted
	public var background: AppearanceBackground = .subtle
	public var motion: AppearanceMotion = .fluid

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
		case colorScheme, textSize, accent, glass, background, motion
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
	}
}
