import Foundation
import NaturalLanguage

/// Resolves spoken self-corrections before numbers are formatted (plan B2):
/// „am Dienstag, nein, am Mittwoch“ → „am Mittwoch“, „5 mg, ich meine 10 mg“
/// → „10 mg“. Conservative: only when the words right before and right after
/// the signal are of the same kind (weekday, date, time, number/dose,
/// vocabulary term, or a short fragment of the same word classes with content
/// words). An ordinary „nein“ or „ich meine“ stays.
public enum SelfCorrectionResolver {
	private static let germanSignals: [[String]] = [
		["nein", "warte"], ["äh", "nein"], ["ähm", "nein"], ["ich", "meine"], ["ich", "mein"], ["besser", "gesagt"],
		["nein"], ["sorry"],
	]
	private static let englishSignals: [[String]] = [
		["no", "wait"], ["i", "mean"], ["sorry"], ["actually"],
	]

	public static func resolve(_ tokens: [TextToken], language: String, vocabulary: Set<String> = []) -> [TextToken] {
		let english = language.lowercased().hasPrefix("en")
		var tokens = tokens
		// Several corrections in one utterance: resolve from the start, one at a time.
		var guardCount = 0
		while guardCount < 8, let next = resolveFirst(tokens, english: english, vocabulary: vocabulary) {
			tokens = next
			guardCount += 1
		}
		return tokens
	}

	// MARK: - One correction

	private struct Word {
		let token: Int
		let text: String
		let lower: String
	}

	private static func resolveFirst(_ tokens: [TextToken], english: Bool, vocabulary: Set<String>) -> [TextToken]? {
		let words: [Word] = tokens.enumerated().compactMap { index, token in
			guard let text = token.wordText else { return nil }
			let normalized = CommandGrammar.normalizedWords(text).joined(separator: " ")
			return normalized.isEmpty ? nil : Word(token: index, text: text, lower: normalized)
		}
		guard words.count >= 3 else { return nil }
		let signals = (english ? englishSignals : germanSignals).sorted { $0.count > $1.count }
		var tags: [NLTag?]?
		for start in 1..<words.count {
			guard let signal = signals.first(where: { phrase in
				start + phrase.count < words.count && Array(words[start..<(start + phrase.count)].map(\.lower)) == phrase
			}) else { continue }
			let after = start + signal.count
			// A sentence end between the earlier words and the signal: it is an answer, not a correction.
			guard !hasSentenceEnd(tokens, from: words[start - 1].token, to: words[start].token),
			      !hasSentenceEnd(tokens, from: words[after - 1].token, to: words[after].token) else { continue }
			if tags == nil { tags = wordClasses(words.map(\.text), english: english) }
			guard let match = match(words, signalStart: start, after: after, english: english, vocabulary: vocabulary, tags: tags ?? nil) else { continue }
			return apply(match, tokens: tokens, words: words)
		}
		return nil
	}

	private struct Match {
		/// Word index where the removed span starts (the corrected words).
		let removeFrom: Int
		/// First word index that stays (the correction).
		let keepFrom: Int
	}

	private static func match(_ words: [Word], signalStart: Int, after: Int, english: Bool, vocabulary: Set<String>, tags: [NLTag?]?) -> Match? {
		// Kinds read the spoken form („14:30“, „3.3.“ stay whole); signals use normalized words.
		let lower = words.map { $0.text.lowercased() }
		// The correction may repeat a preposition or article: „am Dienstag, nein, am Mittwoch“.
		for kind in Kind.allCases {
			if kind == .fragment {
				// Up to three words of the same word classes with a content word:
				// „der rote, nein, der blaue Ordner“.
				guard let tags else { continue }
				for length in stride(from: min(3, signalStart), through: 1, by: -1)
				where fragmentMatch(tags, beforeStart: signalStart - length, length: length, afterStart: after) {
					return Match(removeFrom: signalStart - length, keepFrom: after)
				}
				continue
			}
			for length in stride(from: min(4, signalStart), through: 1, by: -1) {
				let beforeStart = signalStart - length
				guard let before = kind.length(lower, at: beforeStart, english: english, vocabulary: vocabulary, tags: tags),
				      before == length else { continue }
				if let correction = kind.length(lower, at: after, english: english, vocabulary: vocabulary, tags: tags),
				   kind.compatible(lower, beforeStart, length, after, correction, english: english, tags: tags) {
					return Match(removeFrom: beforeStart, keepFrom: after)
				}
				if beforeStart > 0, after + 1 < lower.count, lower[after] == lower[beforeStart - 1],
				   let correction = kind.length(lower, at: after + 1, english: english, vocabulary: vocabulary, tags: tags),
				   kind.compatible(lower, beforeStart, length, after + 1, correction, english: english, tags: tags) {
					return Match(removeFrom: beforeStart - 1, keepFrom: after)
				}
			}
		}
		return nil
	}

	private static func apply(_ match: Match, tokens: [TextToken], words: [Word]) -> [TextToken] {
		let removeStart = words[match.removeFrom].token
		let keepStart = words[match.keepFrom].token
		var result = Array(tokens[..<removeStart])
		var kept = Array(tokens[keepStart...])
		// Keep the capital letter of a sentence start.
		if let first = words[match.removeFrom].text.first, first.isUppercase,
		   removeStart == 0 || hasSentenceEnd(tokens, from: max(removeStart - 1, 0), to: removeStart),
		   case let .word(text)? = kept.first, let initial = text.first, initial.isLowercase {
			kept[0] = .word(initial.uppercased() + text.dropFirst())
		}
		result += kept
		return result
	}

	private static func hasSentenceEnd(_ tokens: [TextToken], from: Int, to: Int) -> Bool {
		guard from < to else { return false }
		for index in from...to {
			let token = tokens[index]
			// The dot of a date („am 3.3., nein“) does not end the sentence.
			if case .modelMark(".", _) = token, index > 0, let previous = tokens[index - 1].wordText,
			   previous.range(of: #"^\d{1,2}\.\d{1,2}$"#, options: .regularExpression) != nil { continue }
			switch token {
			case let .modelMark(glyph, _) where [".", "!", "?"].contains(glyph): return true
			case let .mark(mark) where mark.endsSentence: return true
			case .lineBreak, .paragraphBreak: return true
			default: continue
			}
		}
		return false
	}

	// MARK: - Kinds

	private enum Kind: CaseIterable {
		case weekday, date, time, number, vocabulary, fragment

		func length(_ words: [String], at index: Int, english: Bool, vocabulary: Set<String>, tags: [NLTag?]?) -> Int? {
			guard index < words.count else { return nil }
			switch self {
			case .weekday:
				return (english ? englishWeekdays : germanWeekdays).contains(words[index]) ? 1 : nil
			case .date:
				return SelfCorrectionResolver.dateLength(words, at: index, english: english)
			case .time:
				return SelfCorrectionResolver.timeLength(words, at: index, english: english)
			case .number:
				return SelfCorrectionResolver.numberLength(words, at: index, english: english)
			case .vocabulary:
				return vocabulary.contains(words[index]) ? 1 : nil
			case .fragment:
				return nil // matched by length in `compatible`
			}
		}

		func compatible(_ words: [String], _ beforeStart: Int, _ beforeLength: Int, _ afterStart: Int, _ afterLength: Int, english: Bool, tags: [NLTag?]?) -> Bool {
			switch self {
			case .number:
				// The unit may come only with the correction („zwanzig, nein, dreißig Euro“),
				// but a unit must not get lost („5 mg, nein, 10“ stays).
				let unitBefore = SelfCorrectionResolver.hasUnit(words, start: beforeStart, length: beforeLength, english: english)
				let unitAfter = SelfCorrectionResolver.hasUnit(words, start: afterStart, length: afterLength, english: english)
				return !unitBefore || unitAfter
			default:
				return true
			}
		}
	}

	private static let germanWeekdays: Set<String> = ["montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonnabend", "sonntag"]
	private static let englishWeekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
	private static let germanMonths: Set<String> = ["januar", "jänner", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember"]
	private static let englishMonths: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

	private static func isNumber(_ word: String, english: Bool) -> Bool {
		SpokenNumberFormatter.isNumberWord(word, english: english)
	}

	/// Unit symbols as the model writes them („5 mg“, „10 %“, „20 €“).
	private static let unitSymbols: Set<String> = [
		"mg", "µg", "mcg", "g", "kg", "ml", "l", "cm", "mm", "m", "km", "%", "€", "$", "euro", "euros", "dollar", "dollars",
		"ie", "iu", "mmhg", "°c", "grad",
	]

	static func numberLength(_ words: [String], at index: Int, english: Bool) -> Int? {
		let tokens = words.map { TextToken.word($0) }
		guard let number = SpokenNumberFormatter.parseNumber(tokens, at: index, english: english) else { return nil }
		var length = number.consumed
		if let unit = SpokenNumberFormatter.matchUnit(tokens, at: index + length, english: english) {
			length += unit.consumed
		} else if index + length < words.count, unitSymbols.contains(words[index + length]) {
			length += 1
		}
		return length
	}

	static func hasUnit(_ words: [String], start: Int, length: Int, english: Bool) -> Bool {
		let tokens = words.map { TextToken.word($0) }
		guard let number = SpokenNumberFormatter.parseNumber(tokens, at: start, english: english) else { return false }
		return number.consumed < length
	}

	static func timeLength(_ words: [String], at index: Int, english: Bool) -> Int? {
		let word = words[index]
		if word.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return 1 }
		if english {
			if isNumber(word, english: true), index + 1 < words.count, ["oclock", "o", "am", "pm"].contains(words[index + 1]) {
				return words[index + 1] == "o" && index + 2 < words.count && words[index + 2] == "clock" ? 3 : 2
			}
			if ["half", "quarter"].contains(word), index + 2 < words.count, ["past", "to"].contains(words[index + 1]),
			   isNumber(words[index + 2], english: true) { return 3 }
			return nil
		}
		if word == "halb", index + 1 < words.count, isNumber(words[index + 1], english: false) { return 2 }
		if ["viertel", "dreiviertel"].contains(word), index + 1 < words.count {
			if ["nach", "vor"].contains(words[index + 1]), index + 2 < words.count, isNumber(words[index + 2], english: false) { return 3 }
			if isNumber(words[index + 1], english: false) { return 2 }
		}
		if isNumber(word, english: false), index + 1 < words.count, words[index + 1] == "uhr" {
			if index + 2 < words.count, isNumber(words[index + 2], english: false) { return 3 }
			return 2
		}
		return nil
	}

	static func dateLength(_ words: [String], at index: Int, english: Bool) -> Int? {
		let word = words[index]
		if word.range(of: #"^\d{1,2}\.\d{1,2}\.?(\d{2,4})?$"#, options: .regularExpression) != nil { return 1 }
		let months = english ? englishMonths : germanMonths
		// „March third“
		if english, months.contains(word), index + 1 < words.count, SpokenNumberFormatter.englishOrdinal(words[index + 1]) != nil { return 2 }
		let isOrdinal = english
			? SpokenNumberFormatter.englishOrdinal(word) != nil
			: (SpokenNumberFormatter.germanOrdinal(word) != nil || word.range(of: #"^\d{1,2}\.$"#, options: .regularExpression) != nil)
		if isOrdinal, index + 1 < words.count, months.contains(words[index + 1]) { return 2 }
		if months.contains(word) { return 1 }
		return nil
	}

	// MARK: - Word classes (short fragments)

	private static let contentClasses: Set<NLTag> = [.noun, .adjective, .number, .personalName, .placeName, .organizationName]

	/// Lexical classes per word, or nil when the tagger's words do not line up with ours.
	private static func wordClasses(_ words: [String], english: Bool) -> [NLTag?]? {
		let text = words.joined(separator: " ")
		let tagger = NLTagger(tagSchemes: [.lexicalClass])
		tagger.string = text
		tagger.setLanguage(english ? .english : .german, range: text.startIndex..<text.endIndex)
		var tags: [NLTag?] = []
		tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
			tags.append(tag)
			return true
		}
		return tags.count == words.count ? tags : nil
	}

	fileprivate static func fragmentMatch(_ tags: [NLTag?], beforeStart: Int, length: Int, afterStart: Int) -> Bool {
		guard afterStart + length <= tags.count else { return false }
		let before = tags[beforeStart..<(beforeStart + length)]
		let after = tags[afterStart..<(afterStart + length)]
		guard before.allSatisfy({ $0 != nil }), Array(before) == Array(after) else { return false }
		return before.contains { contentClasses.contains($0!) }
	}
}
