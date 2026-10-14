import Foundation

/// An app a profile applies to.
public struct ProfileApp: Codable, Equatable, Hashable, Identifiable, Sendable {
	public var bundleID: String
	public var name: String
	public var id: String { bundleID }

	public init(bundleID: String, name: String) {
		self.bundleID = bundleID
		self.name = name
	}
}

/// A dictation profile (2.6, C2): a bundle of settings for a kind of work,
/// optionally tied to apps. `nil` values keep the global setting.
public struct DictationProfile: Codable, Equatable, Identifiable, Sendable {
	public var id: String
	public var name: String
	public var symbol: String
	/// Vocabulary domain: picks your terms for this domain, its model memory
	/// and the starter terminology.
	public var domain: ASRProfile
	/// Word packs; nil = the packs active under Vocabulary.
	public var lexiconPacks: [String]?
	public var mode: DictationMode?
	public var spokenPunctuationInNormal: Bool?
	public var codeFormatting: Bool?
	/// Automatic AI step on/off; nil = global.
	public var aiAutomatic: Bool?
	/// AI style for the automatic step and the box ✨; nil = global.
	public var aiStyleID: String?
	public var contextUse: ContextUse?
	public var apps: [ProfileApp]

	public init(
		id: String,
		name: String,
		symbol: String,
		domain: ASRProfile = .general,
		lexiconPacks: [String]? = nil,
		mode: DictationMode? = nil,
		spokenPunctuationInNormal: Bool? = nil,
		codeFormatting: Bool? = nil,
		aiAutomatic: Bool? = nil,
		aiStyleID: String? = nil,
		contextUse: ContextUse? = nil,
		apps: [ProfileApp] = []
	) {
		self.id = id
		self.name = name
		self.symbol = symbol
		self.domain = domain
		self.lexiconPacks = lexiconPacks
		self.mode = mode
		self.spokenPunctuationInNormal = spokenPunctuationInNormal
		self.codeFormatting = codeFormatting
		self.aiAutomatic = aiAutomatic
		self.aiStyleID = aiStyleID
		self.contextUse = contextUse
		self.apps = apps
	}

	public var isBuiltIn: Bool { ProfileSettings.builtIns.contains { $0.id == id } }

	private enum CodingKeys: String, CodingKey {
		case id, name, symbol, domain, lexiconPacks, mode, spokenPunctuationInNormal, codeFormatting
		case aiAutomatic, aiStyleID, contextUse, apps
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Profile"
		symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? "person.crop.circle"
		domain = (try? c.decodeIfPresent(ASRProfile.self, forKey: .domain)) ?? .general
		lexiconPacks = (try? c.decodeIfPresent([String].self, forKey: .lexiconPacks)) ?? nil
		mode = (try? c.decodeIfPresent(DictationMode.self, forKey: .mode)) ?? nil
		spokenPunctuationInNormal = (try? c.decodeIfPresent(Bool.self, forKey: .spokenPunctuationInNormal)) ?? nil
		codeFormatting = (try? c.decodeIfPresent(Bool.self, forKey: .codeFormatting)) ?? nil
		aiAutomatic = (try? c.decodeIfPresent(Bool.self, forKey: .aiAutomatic)) ?? nil
		aiStyleID = (try? c.decodeIfPresent(String.self, forKey: .aiStyleID)) ?? nil
		contextUse = (try? c.decodeIfPresent(ContextUse.self, forKey: .contextUse)) ?? nil
		apps = (try? c.decodeIfPresent([ProfileApp].self, forKey: .apps)) ?? []
	}
}

/// All profiles and how they are chosen.
public struct ProfileSettings: Codable, Equatable, Sendable {
	public static let generalID = "general"
	public static let mailID = "mail"
	public static let codingID = "coding"
	public static let medicalID = "medical"
	public static let aiPromptID = "ai-prompt"

	public static let builtIns: [DictationProfile] = [
		DictationProfile(id: generalID, name: "General", symbol: "person.crop.circle", domain: .general),
		DictationProfile(
			id: mailID, name: "Mail", symbol: "envelope", domain: .general, mode: .normal, aiStyleID: AIStyleCatalog.emailID,
			apps: [ProfileApp(bundleID: "com.apple.mail", name: "Mail"), ProfileApp(bundleID: "org.mozilla.thunderbird", name: "Thunderbird")]
		),
		DictationProfile(
			id: codingID, name: "Coding", symbol: "chevron.left.forwardslash.chevron.right", domain: .technical,
			mode: .normal, spokenPunctuationInNormal: true, codeFormatting: true, aiAutomatic: false,
			apps: [
				ProfileApp(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
				ProfileApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
				ProfileApp(bundleID: "com.apple.Terminal", name: "Terminal"),
			]
		),
		DictationProfile(
			id: aiPromptID, name: "AI prompt", symbol: "bubble.left.and.text.bubble.right", domain: .technical,
			mode: .normal, aiStyleID: AIStyleCatalog.promptID, contextUse: .appOnly,
			apps: [
				ProfileApp(bundleID: "com.openai.chat", name: "ChatGPT"),
				ProfileApp(bundleID: "ai.perplexity.mac", name: "Perplexity"),
			]
		),
		DictationProfile(id: medicalID, name: "Medical", symbol: "cross.case", domain: .medical, mode: .literal, aiStyleID: AIStyleCatalog.cleanID),
	]

	/// Pick the profile of the app you dictate into.
	public var switchByApp = true
	/// Profile when switching by app is off or the app has no profile.
	public var manualProfileID = generalID
	public var profiles: [DictationProfile] = builtIns

	public init() {}

	public func profile(id: String) -> DictationProfile {
		profiles.first { $0.id == id } ?? profiles.first ?? Self.builtIns[0]
	}

	/// The profile for a dictation into the app with this bundle id.
	public func profile(forApp bundleID: String?) -> DictationProfile {
		if switchByApp, let bundleID, let match = profiles.first(where: { $0.apps.contains { $0.bundleID == bundleID } }) {
			return match
		}
		return profile(id: manualProfileID)
	}

	public mutating func save(_ profile: DictationProfile) {
		// An app belongs to one profile only.
		let bundleIDs = Set(profile.apps.map(\.bundleID))
		for index in profiles.indices where profiles[index].id != profile.id {
			profiles[index].apps.removeAll { bundleIDs.contains($0.bundleID) }
		}
		if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
			profiles[index] = profile
		} else {
			profiles.append(profile)
		}
	}

	/// Built-in profiles cannot be deleted; a deleted manual profile falls back to General.
	public mutating func delete(_ id: String) {
		guard !Self.builtIns.contains(where: { $0.id == id }) else { return }
		profiles.removeAll { $0.id == id }
		if manualProfileID == id { manualProfileID = Self.generalID }
	}

	public mutating func restore(_ id: String) {
		guard let builtIn = Self.builtIns.first(where: { $0.id == id }) else { return }
		save(builtIn)
	}

	private enum CodingKeys: String, CodingKey { case switchByApp, manualProfileID, profiles }

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = ProfileSettings()
		switchByApp = (try? c.decodeIfPresent(Bool.self, forKey: .switchByApp)) ?? d.switchByApp
		manualProfileID = (try? c.decodeIfPresent(String.self, forKey: .manualProfileID)) ?? d.manualProfileID
		var stored = (try? c.decodeIfPresent([DictationProfile].self, forKey: .profiles)) ?? d.profiles
		profiles = stored
		// Built-ins missing from an older file come back with their apps.
		for builtIn in Self.builtIns where !stored.contains(where: { $0.id == builtIn.id }) {
			save(builtIn)
		}
	}
}

extension HexSettings {
	/// The settings a dictation into this app runs with: the global settings
	/// with the app's profile laid over them. Nothing is stored.
	public func effective(forApp bundleID: String?) -> HexSettings {
		effective(profile: profiles.profile(forApp: bundleID))
	}

	public func effective(profile: DictationProfile) -> HexSettings {
		var settings = self
		settings.asrProfile = profile.domain
		if let model = profileModelSelections[profile.domain], !model.isEmpty { settings.selectedModel = model }
		if let packs = profile.lexiconPacks { settings.activeLexiconPacks = packs }
		if let mode = profile.mode { settings.dictationMode = mode }
		if let value = profile.spokenPunctuationInNormal { settings.textProcessing.spokenPunctuationInNormal = value }
		if let value = profile.codeFormatting { settings.agentFormattingEnabled = value }
		if let value = profile.aiAutomatic { settings.postProcessing.autoEnabled = value }
		if let style = profile.aiStyleID, settings.postProcessing.allStyles.contains(where: { $0.id == style }) {
			settings.postProcessing.autoStyleID = style
			settings.postProcessing.boxStyleID = style
		}
		if let use = profile.contextUse { settings.postProcessing.context.use = use }
		return settings
	}
}
