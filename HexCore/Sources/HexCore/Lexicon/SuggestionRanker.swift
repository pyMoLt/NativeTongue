import Foundation

public struct Suggestion: Sendable, Equatable, Identifiable {
	public var id: String { term }
	public let term: String
	public let score: Double
	public let isUser: Bool
	public let lang: String
	public let category: String

	public init(term: String, score: Double, isUser: Bool, lang: String, category: String) {
		self.term = term
		self.score = score
		self.isUser = isUser
		self.lang = lang
		self.category = category
	}
}

/// Top-N similar lexicon terms for a word or short phrase (plan 5.7).
///
/// score = 0.45 × phonetic similarity (normalized Levenshtein of the key in the
/// entry language) + 0.30 × Jaro-Winkler of the spelling + 0.15 × source
/// (user 1.0 / active-profile pack 0.6 / other pack 0.3) + 0.10 × language fit.
public struct SuggestionRanker: Sendable {
	public let indexes: [LexiconIndex]

	public init(indexes: [LexiconIndex]) {
		self.indexes = indexes
	}

	public func suggestions(for text: String, language: String, profile: ASRProfile?, limit: Int = 5) -> [Suggestion] {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count >= 2 else { return [] }
		var best: [String: Suggestion] = [:]
		func consider(_ item: LexiconIndex.Item, score: Double) {
			guard item.entry.term != trimmed else { return }
			if let existing = best[item.entry.term], existing.score >= score { return }
			best[item.entry.term] = Suggestion(
				term: item.entry.term, score: score, isUser: item.isUser,
				lang: item.entry.lang, category: item.entry.category
			)
		}
		for index in indexes {
			for item in index.aliasMatches(trimmed) { consider(item, score: 1.0) }
			for item in index.exactMatches(trimmed) { consider(item, score: 0.99) }
			for item in index.candidates(for: trimmed) {
				consider(item, score: score(item, for: trimmed, language: language, profile: profile))
			}
		}
		return best.values.sorted { lhs, rhs in
			lhs.score == rhs.score ? lhs.term < rhs.term : lhs.score > rhs.score
		}.prefix(limit).map { $0 }
	}

	public func score(_ item: LexiconIndex.Item, for text: String, language: String, profile: ASRProfile?) -> Double {
		let phonetic = StringSimilarity.normalizedLevenshtein(
			PhoneticKey.key(text, language: item.entry.lang),
			item.languageKey
		)
		let spelling = StringSimilarity.jaroWinkler(text.lowercased(), item.entry.term.lowercased())
		let source: Double = item.isUser ? 1.0 : (profile != nil && item.packProfile == profile ? 0.6 : 0.3)
		return 0.45 * phonetic + 0.30 * spelling + 0.15 * source + 0.10 * Self.languageFit(item.entry, dictationLanguage: language)
	}

	static func languageFit(_ entry: LexiconEntry, dictationLanguage: String) -> Double {
		if entry.lang == dictationLanguage { return 1 }
		if entry.lang == "la", entry.category != "tech" { return 1 }
		return 0
	}
}
