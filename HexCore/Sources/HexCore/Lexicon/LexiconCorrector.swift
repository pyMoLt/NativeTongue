import Foundation

/// Conservative automatic term correction (plan 5.7), both modes.
///
/// A word sequence (1–3 words) is replaced only when one rule applies:
/// 1. **Alias**: exact, case-insensitive match of a known misrecognition.
/// 2. **Casing**: exact term match that differs only in casing, for
///    case-sensitive entries (brands) or multi-word terms ("Nervus Vagus").
/// 3. **Fuzzy**: entry may auto-replace (user entry, or pack entry in literal
///    mode with the setting on), score ≥ 0.90 with a gap ≥ 0.06 to the runner-up
///    (long words ≥ 12 letters: ≥ 0.85 with a gap ≥ 0.15),
///    no word of the sequence is a valid general word (de + en), no stop word,
///    language fits, not a known confusable, at least 5 letters.
public struct LexiconCorrector: Sendable {
	public struct Options: Sendable, Equatable {
		public var mode: DictationMode
		public var language: String
		public var profile: ASRProfile?
		/// „Fachwörter automatisch ersetzen" (literal mode, pack entries).
		public var autoReplacePackTermsInLiteral: Bool

		public init(mode: DictationMode, language: String = "de", profile: ASRProfile? = nil, autoReplacePackTermsInLiteral: Bool = true) {
			self.mode = mode
			self.language = language
			self.profile = profile
			self.autoReplacePackTermsInLiteral = autoReplacePackTermsInLiteral
		}
	}

	public let ranker: SuggestionRanker
	public let wordChecker: (any GeneralWordChecker)?
	public var options: Options

	public init(indexes: [LexiconIndex], wordChecker: (any GeneralWordChecker)?, options: Options) {
		self.ranker = SuggestionRanker(indexes: indexes)
		self.wordChecker = wordChecker
		self.options = options
	}

	public static let stopWords: Set<String> = Set("""
	und in für die der das den dem des ein eine einer einen oder mit auf zu im am an ist sind war wird werden als auch
	nicht noch nur aus bei nach von vor über unter durch ohne um wie was wer wo hier dort diese dieser dieses sehr bitte
	danach wieder weitere folgt folgen sollen bleiben soll the and of to a in is are for with on as by be this that please
	""".split(whereSeparator: \.isWhitespace).map(String.init))

	public func correct(_ tokens: [TextToken]) -> (tokens: [TextToken], corrections: [LexiconCorrection]) {
		var output: [TextToken] = []
		var corrections: [LexiconCorrection] = []
		var index = 0
		while index < tokens.count {
			guard case .word = tokens[index] else {
				output.append(tokens[index])
				index += 1
				continue
			}
			var matched = false
			for length in stride(from: 3, through: 1, by: -1) {
				let window = index ..< min(index + length, tokens.count)
				let words = tokens[window].compactMap(\.wordText)
				guard words.count == length, words.allSatisfy(Self.isPlainWord) else { continue }
				let span = words.joined(separator: " ")
				if let (term, rule) = replacement(for: span, words: words) {
					output += term.split(separator: " ").map { .word(String($0)) }
					corrections.append(LexiconCorrection(original: span, replacement: term, rule: rule))
					index += length
					matched = true
					break
				}
			}
			if !matched {
				output.append(tokens[index])
				index += 1
			}
		}
		return (output, corrections)
	}

	/// Replacement for one word sequence, or `nil`.
	func replacement(for span: String, words: [String]) -> (String, LexiconCorrection.Rule)? {
		let lower = span.lowercased()
		for index in ranker.indexes {
			if let item = index.aliasMatches(span).first(where: isActive), item.entry.term != span {
				return (item.entry.term, .alias)
			}
		}
		var exactTerm: LexiconIndex.Item?
		for index in ranker.indexes {
			if let item = index.exactMatches(span).first(where: isActive) {
				exactTerm = exactTerm ?? item
				if item.entry.term != span, item.entry.caseSensitive || words.count > 1,
				   item.isUser || words.count > 1 || !isGeneralWord(span) {
					return (item.entry.term, .casing)
				}
			}
		}
		// Already a known term (any casing) → nothing to fix.
		if exactTerm != nil { return nil }
		guard wordChecker != nil else { return nil }
		guard span.filter(\.isLetter).count >= 5 else { return nil }
		guard !words.contains(where: { Self.stopWords.contains($0.lowercased()) }) else { return nil }
		guard !words.contains(where: isGeneralWord) else { return nil }

		var scored: [(item: LexiconIndex.Item, score: Double)] = []
		for index in ranker.indexes {
			for item in index.candidates(for: span) where isActive(item) {
				scored.append((item, ranker.score(item, for: span, language: options.language, profile: options.profile)))
			}
		}
		scored.sort { $0.score > $1.score }
		guard let best = scored.first else { return nil }
		let runnerUp = scored.first(where: { $0.item.entry.term.lowercased() != best.item.entry.term.lowercased() })?.score ?? 0
		let gap = best.score - runnerUp
		// Standard: score ≥ 0.90 and gap ≥ 0.06. Long words (≥ 12 letters) with a
		// clear single winner may pass at 0.85 (e.g. "Mykopenolatmophetil": the
		// p/ph spelling changes the Kölner key; best 0.87, runner-up 0.69).
		let letters = span.filter(\.isLetter).count
		let clear = best.score >= 0.90 && gap >= 0.06
		let clearLong = letters >= 12 && best.score >= 0.85 && gap >= 0.15
		guard clear || clearLong else { return nil }
		let entry = best.item.entry
		guard mayAutoReplace(best.item), best.item.isUser || languageFits(entry) else { return nil }
		guard !entry.confusableWith.contains(where: { $0.lowercased() == lower }) else { return nil }
		return (entry.term, .fuzzy)
	}

	/// Stop word or valid word of the dictation language, German or English
	/// ("mit" must never become "MIT", "The" never "THE").
	private func isGeneralWord(_ word: String) -> Bool {
		if Self.stopWords.contains(word.lowercased()) { return true }
		guard let wordChecker else { return false }
		return wordChecker.isValidWord(word, language: options.language)
			|| (options.language != "en" && wordChecker.isValidWord(word, language: "en"))
			|| (options.language != "de" && wordChecker.isValidWord(word, language: "de"))
	}

	private func isActive(_ item: LexiconIndex.Item) -> Bool {
		guard item.isUser, let profile = item.entry.profile else { return true }
		return profile == options.profile
	}

	private func mayAutoReplace(_ item: LexiconIndex.Item) -> Bool {
		if item.isUser { return item.entry.autoReplace }
		return options.mode == .literal && options.autoReplacePackTermsInLiteral
	}

	private func languageFits(_ entry: LexiconEntry) -> Bool {
		if entry.category == "tech" { return true }
		if options.language == "en" { return entry.lang == "en" }
		return entry.lang == "de" || entry.lang == "la"
	}

	/// Skips identifiers produced by the agent formatter (`code`, file.ext, snake_case, /cmd).
	static func isPlainWord(_ word: String) -> Bool {
		!word.contains(where: { "`/_\\@#".contains($0) }) && word.contains(where: \.isLetter)
	}
}
