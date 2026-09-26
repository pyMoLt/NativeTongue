import Foundation

/// One term of a word pack or of the user lexicon (plan 5.7).
public struct LexiconEntry: Codable, Sendable, Hashable, Identifiable {
	public var id: String { "\(lang):\(term)" }
	/// Correct spelling.
	public var term: String
	/// `de`, `en` or `la`.
	public var lang: String
	/// `diagnosis`, `drug`, `anatomy`, `general-medical`, `tech`, `user`, …
	public var category: String
	/// Known misrecognitions that are replaced directly.
	public var aliases: [String]
	/// Similar terms that are never swapped automatically (e.g. Nävus ↔ Nervus).
	public var confusableWith: [String]
	/// Brands and identifiers (GitHub, SwiftUI) whose casing is corrected.
	public var caseSensitive: Bool
	/// Fuzzy auto-replacement allowed (user entries default true, pack entries false).
	public var autoReplace: Bool
	/// Only active in this profile; `nil` = all profiles.
	public var profile: ASRProfile?

	public init(
		term: String,
		lang: String,
		category: String,
		aliases: [String] = [],
		confusableWith: [String] = [],
		caseSensitive: Bool? = nil,
		autoReplace: Bool = false,
		profile: ASRProfile? = nil
	) {
		self.term = term
		self.lang = lang
		self.category = category
		self.aliases = aliases
		self.confusableWith = confusableWith
		self.caseSensitive = caseSensitive ?? Self.looksCaseSensitive(term)
		self.autoReplace = autoReplace
		self.profile = profile
	}

	private enum CodingKeys: String, CodingKey {
		case term, lang, category, aliases, confusableWith, caseSensitive, autoReplace, profile
	}

	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		let term = try values.decode(String.self, forKey: .term)
		self.init(
			term: term,
			lang: try values.decodeIfPresent(String.self, forKey: .lang) ?? "de",
			category: try values.decodeIfPresent(String.self, forKey: .category) ?? "general",
			aliases: try values.decodeIfPresent([String].self, forKey: .aliases) ?? [],
			confusableWith: try values.decodeIfPresent([String].self, forKey: .confusableWith) ?? [],
			caseSensitive: try values.decodeIfPresent(Bool.self, forKey: .caseSensitive),
			autoReplace: try values.decodeIfPresent(Bool.self, forKey: .autoReplace) ?? false,
			profile: try values.decodeIfPresent(ASRProfile.self, forKey: .profile)
		)
	}

	public func encode(to encoder: Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encode(term, forKey: .term)
		try values.encode(lang, forKey: .lang)
		try values.encode(category, forKey: .category)
		if !aliases.isEmpty { try values.encode(aliases, forKey: .aliases) }
		if !confusableWith.isEmpty { try values.encode(confusableWith, forKey: .confusableWith) }
		try values.encode(caseSensitive, forKey: .caseSensitive)
		try values.encode(autoReplace, forKey: .autoReplace)
		try values.encodeIfPresent(profile, forKey: .profile)
	}

	/// Inner capitals (GitHub, SwiftUI, AVFoundation) or all caps (WHO, EKG).
	static func looksCaseSensitive(_ term: String) -> Bool {
		let letters = term.filter(\.isLetter)
		guard letters.count >= 2 else { return false }
		if letters.dropFirst().contains(where: \.isUppercase) { return true }
		return false
	}
}

/// A word pack file (`local-asr-docs/06-wortlisten/packs/*.json`).
public struct LexiconPack: Codable, Sendable {
	public var id: String
	public var version: String?
	public var license: String?
	public var entryCount: Int?
	public var entries: [LexiconEntry]

	public init(id: String, version: String? = nil, license: String? = nil, entries: [LexiconEntry]) {
		self.id = id
		self.version = version
		self.license = license
		self.entryCount = entries.count
		self.entries = entries
	}

	private enum CodingKeys: String, CodingKey { case id, version, license, entryCount, entries }

	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		id = try values.decode(String.self, forKey: .id)
		if let text = try? values.decodeIfPresent(String.self, forKey: .version) {
			version = text
		} else if let number = try? values.decodeIfPresent(Int.self, forKey: .version) {
			version = String(number)
		} else {
			version = nil
		}
		license = try? values.decodeIfPresent(String.self, forKey: .license)
		entries = try values.decode([LexiconEntry].self, forKey: .entries)
		entryCount = (try? values.decodeIfPresent(Int.self, forKey: .entryCount)) ?? entries.count
	}

	/// Packs belong to the profile their id names (medical-de → medical).
	public var profile: ASRProfile? {
		Self.profile(forPackID: id)
	}

	public static func profile(forPackID id: String) -> ASRProfile? {
		if id.hasPrefix("medical") || id.hasPrefix("anatomy") { return .medical }
		if id.hasPrefix("technical") { return .technical }
		return nil
	}
}

/// Metadata of an installed pack (without loading its entries).
public struct LexiconPackInfo: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var version: String?
	public var license: String?
	public var entryCount: Int
	public var fileBytes: Int

	public init(id: String, version: String?, license: String?, entryCount: Int, fileBytes: Int) {
		self.id = id
		self.version = version
		self.license = license
		self.entryCount = entryCount
		self.fileBytes = fileBytes
	}
}

/// The user's own lexicon (`lexicon/user.json`).
public struct UserLexicon: Codable, Sendable, Equatable {
	public var version = 1
	public var entries: [LexiconEntry]

	public init(entries: [LexiconEntry] = []) {
		self.entries = entries
	}
}

/// A replacement made automatically by `LexiconCorrector`; kept in the
/// `DictationDocument` so the dictation box can underline and undo it.
public struct LexiconCorrection: Codable, Sendable, Equatable, Hashable {
	public enum Rule: String, Codable, Sendable { case alias, casing, fuzzy }
	public var original: String
	public var replacement: String
	public var rule: Rule

	public init(original: String, replacement: String, rule: Rule) {
		self.original = original
		self.replacement = replacement
		self.rule = rule
	}
}
