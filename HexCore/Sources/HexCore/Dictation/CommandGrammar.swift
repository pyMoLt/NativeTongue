import Foundation

public enum CommandAction: Sendable, Equatable {
	case structural(StructuralCommand)
	case edit(EditCommand)
	case format(FormatCommand)
	case box(BoxCommand)
	/// A text snippet's trigger: the expanded snippet text (plan B6).
	case snippet(String)
}

/// Spoken command tables (German + English). Data only; matching lives in the
/// classifier and the inline renderer. See plan appendix A.
public enum CommandGrammar {
	public struct Phrase: Sendable {
		public let words: [String]      // normalized, e.g. ["neuer", "absatz"]
		public let english: Bool
		/// Spelling for display in the commands page.
		public let text: String
		public init(_ text: String, english: Bool = false) {
			self.text = text
			self.words = CommandGrammar.normalizedWords(text)
			self.english = english
		}
	}

	// MARK: Normalization

	/// Lowercases, removes punctuation (including hyphens) and fillers at the edges.
	public static func normalizedWords(_ text: String) -> [String] {
		let lowered = text.lowercased()
		let cleaned = String(lowered.unicodeScalars.map { scalar -> Character in
			CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) ? Character(scalar) : " "
		})
		var words = cleaned.split(separator: " ").map(String.init)
		let fillers: Set<String> = ["äh", "ähm", "öh", "hm", "hmm", "uh", "um", "uhm", "erm"]
		while let first = words.first, fillers.contains(first) { words.removeFirst() }
		while let last = words.last, fillers.contains(last) { words.removeLast() }
		return words
	}

	// MARK: Structural (normal + literal; isolated or at an utterance edge with a pause)

	public static let structural: [(Phrase, StructuralCommand)] = [
		(Phrase("neuer Absatz"), .newParagraph), (Phrase("neuen Absatz"), .newParagraph),
		(Phrase("neue Absatz"), .newParagraph), (Phrase("nächster Absatz"), .newParagraph),
		(Phrase("new paragraph", english: true), .newParagraph), (Phrase("next paragraph", english: true), .newParagraph),
		(Phrase("neue Zeile"), .newLine), (Phrase("neuer Zeile"), .newLine), (Phrase("neuen Zeile"), .newLine), (Phrase("nächste Zeile"), .newLine),
		(Phrase("Zeilenumbruch"), .newLine),
		(Phrase("new line", english: true), .newLine), (Phrase("next line", english: true), .newLine),
		(Phrase("line break", english: true), .newLine),
	]
	/// Only valid as a complete, isolated utterance ("Absatz" alone is too common in text).
	public static let structuralIsolatedOnly: [(Phrase, StructuralCommand)] = [
		(Phrase("Absatz"), .newParagraph), (Phrase("paragraph", english: true), .newParagraph),
	]

	// MARK: Edit (isolated utterance only)

	public static let edit: [(Phrase, EditCommand)] = [
		(Phrase("streich das"), .deleteLastUtterance), (Phrase("streiche das"), .deleteLastUtterance),
		(Phrase("lösch das"), .deleteLastUtterance), (Phrase("lösche das"), .deleteLastUtterance),
		// Common ASR spellings of the same phrase.
		(Phrase("streich dass"), .deleteLastUtterance), (Phrase("streiche dass"), .deleteLastUtterance),
		(Phrase("lösch dass"), .deleteLastUtterance), (Phrase("lösche dass"), .deleteLastUtterance),
		(Phrase("strich das"), .deleteLastUtterance), (Phrase("streicht das"), .deleteLastUtterance),
		(Phrase("das war falsch"), .deleteLastUtterance), (Phrase("das ist falsch"), .deleteLastUtterance),
		(Phrase("scratch that", english: true), .deleteLastUtterance), (Phrase("delete that", english: true), .deleteLastUtterance),
		(Phrase("scratch this", english: true), .deleteLastUtterance), (Phrase("that was wrong", english: true), .deleteLastUtterance),
		(Phrase("streich den letzten Satz"), .deleteLastSentence), (Phrase("streiche den letzten Satz"), .deleteLastSentence),
		(Phrase("lösche den letzten Satz"), .deleteLastSentence), (Phrase("lösch den letzten Satz"), .deleteLastSentence),
		(Phrase("letzten Satz löschen"), .deleteLastSentence),
		(Phrase("delete last sentence", english: true), .deleteLastSentence), (Phrase("delete the last sentence", english: true), .deleteLastSentence),
		(Phrase("lösche das letzte Wort"), .deleteLastWord), (Phrase("lösch das letzte Wort"), .deleteLastWord),
		(Phrase("streich das letzte Wort"), .deleteLastWord), (Phrase("streiche das letzte Wort"), .deleteLastWord),
		(Phrase("lösche letztes Wort"), .deleteLastWord), (Phrase("lösch letztes Wort"), .deleteLastWord),
		(Phrase("letztes Wort löschen"), .deleteLastWord), (Phrase("das letzte Wort löschen"), .deleteLastWord),
		(Phrase("delete last word", english: true), .deleteLastWord), (Phrase("delete the last word", english: true), .deleteLastWord),
		(Phrase("rückgängig"), .undo), (Phrase("mach das rückgängig"), .undo), (Phrase("rückgängig machen"), .undo),
		(Phrase("mach rückgängig"), .undo), (Phrase("zurück"), .undo),
		(Phrase("undo that", english: true), .undo), (Phrase("undo", english: true), .undo), (Phrase("go back", english: true), .undo),
		(Phrase("alles löschen"), .clearAll), (Phrase("von vorn"), .clearAll), (Phrase("von vorne"), .clearAll),
		(Phrase("noch mal von vorn"), .clearAll), (Phrase("noch mal von vorne"), .clearAll),
		(Phrase("nochmal von vorn"), .clearAll), (Phrase("nochmal von vorne"), .clearAll),
		(Phrase("clear all", english: true), .clearAll), (Phrase("start over", english: true), .clearAll),
	]

	/// Shown on the commands page next to the fixed phrases.
	public static let parameterizedEditExamples: [(Phrase, EditCommand)] = [
		(Phrase("lösche die letzten drei Wörter"), .deleteLastWords(3)),
		(Phrase("delete the last three words", english: true), .deleteLastWords(3)),
		(Phrase("ersetze Montag durch Dienstag"), .replace("Montag", with: "Dienstag")),
		(Phrase("replace Monday with Tuesday", english: true), .replace("Monday", with: "Tuesday")),
	]

	/// An edit command spoken as a whole utterance: fixed phrases, „lösche die
	/// letzten N Wörter“ (N = 2…10) and „ersetze X durch Y“ / „replace X with Y“.
	/// `text` keeps the original spelling for the replacement.
	public static func editCommand(_ text: String, english: Bool) -> EditCommand? {
		let words = normalizedWords(text)
		guard !words.isEmpty else { return nil }
		if let fixed = isolated(words, in: edit, english: english) { return fixed }
		if let count = lastWordsCount(words, english: english) { return .deleteLastWords(count) }
		return replacement(text, english: english)
	}

	private static let germanSmallNumbers: [String: Int] = [
		"zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10,
	]
	private static let englishSmallNumbers: [String: Int] = [
		"two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
	]

	private static func lastWordsCount(_ words: [String], english: Bool) -> Int? {
		func number(_ word: String, table: [String: Int]) -> Int? {
			if let value = Int(word), (2...10).contains(value) { return value }
			return table[word]
		}
		// lösch(e)/streich(e) [die] letzten N Wörter
		if ["lösche", "lösch", "streiche", "streich"].contains(words.first ?? "") {
			var rest = Array(words.dropFirst())
			if rest.first == "die" { rest.removeFirst() }
			if rest.count == 3, rest[0] == "letzten", ["wörter", "worte"].contains(rest[2]),
			   let count = number(rest[1], table: germanSmallNumbers) { return count }
		}
		// letzten N Wörter löschen
		if words.count == 4, words[0] == "letzten", ["wörter", "worte"].contains(words[2]), words[3] == "löschen",
		   let count = number(words[1], table: germanSmallNumbers) { return count }
		// delete/scratch [the] last N words
		if english, ["delete", "scratch", "remove"].contains(words.first ?? "") {
			var rest = Array(words.dropFirst())
			if rest.first == "the" { rest.removeFirst() }
			if rest.count == 3, rest[0] == "last", rest[2] == "words",
			   let count = number(rest[1], table: englishSmallNumbers) { return count }
		}
		return nil
	}

	/// „ersetze X durch Y“, „ersetz X mit Y“, „replace X with Y“. Both sides are
	/// short (≤ 6 words) so ordinary sentences are not taken for commands.
	private static func replacement(_ text: String, english: Bool) -> EditCommand? {
		let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?")))
		var patterns = [#"^(?:ersetze|ersetz|ersetzt)\s+(.+?)\s+(?:durch|mit)\s+(.+)$"#]
		if english { patterns.append(#"^replace\s+(.+?)\s+(?:with|by)\s+(.+)$"#) }
		for pattern in patterns {
			guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
			      let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
			      let oldRange = Range(match.range(at: 1), in: trimmed), let newRange = Range(match.range(at: 2), in: trimmed)
			else { continue }
			let old = cleanReplacementSide(String(trimmed[oldRange]))
			let new = cleanReplacementSide(String(trimmed[newRange]))
			let oldWords = normalizedWords(old), newWords = normalizedWords(new)
			guard !oldWords.isEmpty, !newWords.isEmpty, oldWords.count <= 6, newWords.count <= 6, oldWords != newWords else { return nil }
			return .replace(old, with: new)
		}
		return nil
	}

	/// Quotes and edge punctuation are not part of the words to replace.
	private static func cleanReplacementSide(_ text: String) -> String {
		text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"„“”‚‘’'«».,;:!?")))
	}

	// MARK: Format (literal)

	/// Complete isolated utterances.
	public static let formatIsolated: [(Phrase, FormatCommand)] = [
		(Phrase("groß"), .capitalizeNext), (Phrase("klein"), .lowercaseNext),
		(Phrase("Spiegelstrich"), .bullet), (Phrase("Aufzählungspunkt"), .bullet),
		(Phrase("bullet", english: true), .bullet), (Phrase("bullet point", english: true), .bullet),
		(Phrase("Nummerierung"), .numberedItem), (Phrase("nächster Punkt nummeriert"), .numberedItem),
		(Phrase("numbered item", english: true), .numberedItem),
	]
	/// Inline phrases that affect the following word(s).
	public static let formatInline: [(Phrase, FormatCommand)] = [
		(Phrase("großschreiben"), .capitalizeNext), (Phrase("großgeschrieben"), .capitalizeNext),
		(Phrase("alles groß"), .allCapsNext), (Phrase("Großbuchstaben"), .allCapsNext),
		(Phrase("kleinschreiben"), .lowercaseNext),
		(Phrase("cap", english: true), .capitalizeNext), (Phrase("all caps", english: true), .allCapsNext),
		(Phrase("no caps", english: true), .lowercaseNext),
		(Phrase("fett an"), .boldStart), (Phrase("fett aus"), .boldEnd),
		(Phrase("kursiv an"), .italicStart), (Phrase("kursiv aus"), .italicEnd),
		(Phrase("bold on", english: true), .boldStart), (Phrase("bold off", english: true), .boldEnd),
		(Phrase("italic on", english: true), .italicStart), (Phrase("italic off", english: true), .italicEnd),
	]
	/// Prefix at the beginning of an utterance ("Überschrift Befund" → heading).
	public static let formatPrefix: [(Phrase, FormatCommand)] = [
		(Phrase("Überschrift"), .heading), (Phrase("heading", english: true), .heading),
		(Phrase("Spiegelstrich"), .bullet), (Phrase("Aufzählungspunkt"), .bullet),
	]

	// MARK: Dictation box (isolated, only when the box is open)

	public static let box: [(Phrase, BoxCommand)] = [
		(Phrase("Text übertragen"), .transfer), (Phrase("Diktat übertragen"), .transfer),
		(Phrase("transfer text", english: true), .transfer),
		(Phrase("buchstabieren"), .spell), (Phrase("spell that", english: true), .spell),
	]

	// MARK: Inline punctuation (literal only). Longer phrases first.

	public static let punctuation: [(Phrase, PunctuationMark)] = {
		let table: [(String, PunctuationMark, Bool)] = [
			("Punkt", .period, false), ("period", .period, true), ("full stop", .period, true),
			("Komma", .comma, false), ("Kommer", .comma, false), ("Beistrich", .comma, false), ("comma", .comma, true),
			("Doppelpunkt", .colon, false), ("Doppel Punkt", .colon, false), ("colon", .colon, true),
			("Semikolon", .semicolon, false), ("Semi Kolon", .semicolon, false), ("Strichpunkt", .semicolon, false), ("Strich Punkt", .semicolon, false),
			("semicolon", .semicolon, true), ("semi colon", .semicolon, true),
			("Fragezeichen", .question, false), ("Frage Zeichen", .question, false), ("question mark", .question, true),
			("Ausrufezeichen", .exclamation, false), ("Ausrufe Zeichen", .exclamation, false), ("Ausruf Zeichen", .exclamation, false),
			("exclamation mark", .exclamation, true), ("exclamation point", .exclamation, true),
			("Bindestrich", .hyphen, false), ("binde strich", .hyphen, false), ("Binde Stich", .hyphen, false), ("hyphen", .hyphen, true),
			("Gedankenstrich", .dash, false), ("Gedanken Strich", .dash, false), ("em dash", .dash, true), ("en dash", .dash, true), ("dash", .dash, true),
			("Schrägstrich", .slash, false), ("Schräg Strich", .slash, false), ("slash", .slash, true),
			("Backslash", .backslash, false), ("umgekehrter Schrägstrich", .backslash, false),
			("Unterstrich", .underscore, false), ("Unter Strich", .underscore, false), ("underscore", .underscore, true),
			("at Zeichen", .at, false), ("Klammeraffe", .at, false), ("at sign", .at, true),
			("Und Zeichen", .ampersand, false), ("ampersand", .ampersand, true),
			("Prozentzeichen", .percent, false), ("percent sign", .percent, true),
			("Klammer auf", .parenOpen, false), ("runde Klammer auf", .parenOpen, false), ("öffnende Klammer", .parenOpen, false),
			("Klammer zu", .parenClose, false), ("Klamme zu", .parenClose, false), ("Klammern zu", .parenClose, false), ("runde Klammer zu", .parenClose, false),
			("Klammern auf", .parenOpen, false),
			("schließende Klammer", .parenClose, false),
			("open parenthesis", .parenOpen, true), ("open paren", .parenOpen, true),
			("close parenthesis", .parenClose, true), ("close paren", .parenClose, true),
			("eckige Klammer auf", .bracketOpen, false), ("eckige Klammer zu", .bracketClose, false),
			("open bracket", .bracketOpen, true), ("close bracket", .bracketClose, true),
			("geschweifte Klammer auf", .braceOpen, false), ("geschweifte Klammer zu", .braceClose, false),
			("open brace", .braceOpen, true), ("close brace", .braceClose, true),
			("Anführungszeichen auf", .quoteOpen, false), ("Anführungszeichen zu", .quoteClose, false),
			("Anführungs Zeichen auf", .quoteOpen, false), ("Anführungs Zeichen zu", .quoteClose, false),
			("Gänsefüßchen auf", .quoteOpen, false), ("Gänsefüßchen zu", .quoteClose, false),
			("Zitat Anfang", .quoteOpen, false), ("Zitat Ende", .quoteClose, false),
			("open quote", .quoteOpen, true), ("close quote", .quoteClose, true),
			("begin quote", .quoteOpen, true), ("end quote", .quoteClose, true),
			("einfaches Anführungszeichen auf", .singleQuoteOpen, false), ("einfaches Anführungszeichen zu", .singleQuoteClose, false),
			("open single quote", .singleQuoteOpen, true), ("close single quote", .singleQuoteClose, true),
			("Auslassungspunkte", .ellipsis, false), ("ellipsis", .ellipsis, true),
			("Leerzeichen", .space, false), ("space", .space, true),
		]
		return table
			.map { (Phrase($0.0, english: $0.2), $0.1) }
			.sorted { $0.0.words.count > $1.0.words.count }
	}()

	// MARK: Matching helpers

	/// Whole-utterance match.
	public static func isolated<T>(_ words: [String], in table: [(Phrase, T)], english: Bool) -> T? {
		table.first { (english || !$0.0.english) && $0.0.words == words }?.1
	}

	/// Longest phrase in `table` that starts at `index` of `words`.
	public static func match<T>(_ words: [String], at index: Int, in table: [(Phrase, T)], english: Bool) -> (T, length: Int)? {
		var best: (T, Int)?
		for (phrase, value) in table where english || !phrase.english {
			let n = phrase.words.count
			guard n > 0, index + n <= words.count, Array(words[index..<(index + n)]) == phrase.words else { continue }
			if best == nil || n > best!.1 { best = (value, n) }
		}
		return best.map { ($0.0, length: $0.1) }
	}
}
