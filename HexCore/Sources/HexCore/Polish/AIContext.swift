import Foundation

/// How a dictation uses the text field it goes into (2.6, C4).
public enum ContextUse: String, Codable, CaseIterable, Equatable, Sendable {
	case off
	/// Only the name of the app (and profile).
	case appOnly
	/// The text before the cursor is analysed on this Mac; the AI only gets
	/// short hints derived from it (never the raw text, unless the
	/// experimental option is on).
	case analyzed

	public var displayName: String {
		switch self {
		case .off: "Off"
		case .appOnly: "App only"
		case .analyzed: "Analyse the text field"
		}
	}
}

/// Which hints are derived from the text field, and how much text is read.
public struct ContextSettings: Codable, Equatable, Sendable {
	public var use: ContextUse = .off
	/// Capitals and spaces fit what is already written (no AI needed).
	public var continuation = true
	/// Names and rare words from the field keep their spelling.
	public var terms = true
	/// Formal or informal address (Sie/du) like the surrounding text.
	public var address = true
	/// Language of the surrounding text.
	public var language = true
	/// Kind of app (mail, chat, code, AI assistant) via app and profile.
	public var appType = true
	/// Continues a list item without a new list marker.
	public var listFormat = true
	/// Experimental: also give the AI the nearby text itself.
	public var sendNearbyText = false
	/// Characters read before the cursor (100…1000).
	public var characters = 300

	public static let characterRange = 100 ... 1000

	public init() {}

	private enum CodingKeys: String, CodingKey {
		case use, continuation, terms, address, language, appType, listFormat, sendNearbyText, characters
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = ContextSettings()
		func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
			(try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
		}
		use = value(.use, d.use)
		continuation = value(.continuation, d.continuation)
		terms = value(.terms, d.terms)
		address = value(.address, d.address)
		language = value(.language, d.language)
		appType = value(.appType, d.appType)
		listFormat = value(.listFormat, d.listFormat)
		sendNearbyText = value(.sendNearbyText, d.sendNearbyText)
		characters = min(max(value(.characters, d.characters), Self.characterRange.lowerBound), Self.characterRange.upperBound)
	}
}

/// What was read from the target app when the dictation started. Only in
/// memory for that one job: never stored, never logged.
public struct AIContext: Equatable, Sendable {
	public var appName: String?
	public var profileName: String?
	/// Text right before the cursor (up to `ContextSettings.characters`).
	public var textBeforeCursor: String?

	public init(appName: String? = nil, profileName: String? = nil, textBeforeCursor: String? = nil) {
		self.appName = appName
		self.profileName = profileName
		self.textBeforeCursor = textBeforeCursor
	}
}

/// Hints derived from the text field, on this Mac and without a model.
public struct ContextHints: Equatable, Sendable {
	public enum Position: Equatable, Sendable { case empty, sentenceStart, midSentence }
	public enum Address: Equatable, Sendable { case formal, informal }

	public var position: Position = .empty
	public var needsLeadingSpace = false
	/// Names and rare words written in the field.
	public var terms: [String] = []
	public var address: Address?
	public var language: String?
	/// "- ", "• ", "1. " when the cursor is in a list item.
	public var listMarker: String?
	public var appName: String?
	public var profileName: String?

	public init() {}
}

public enum ContextAnalyzer {
	public static let maximumTerms = 20

	/// Analyses the text before the cursor. `isGeneralWord` filters ordinary
	/// dictionary words out of the term list.
	public static func analyze(_ context: AIContext, isGeneralWord: (String, String) -> Bool = { _, _ in false }) -> ContextHints {
		var hints = ContextHints()
		hints.appName = context.appName
		hints.profileName = context.profileName
		guard let before = context.textBeforeCursor, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return hints
		}
		// Position and spacing at the cursor.
		let lastChar = before.last!
		let trimmed = before.trimmingCharacters(in: .whitespaces)
		if lastChar == "\n" || trimmed.isEmpty {
			hints.position = .sentenceStart
		} else if let mark = trimmed.last, ".!?".contains(mark) {
			hints.position = .sentenceStart
		} else {
			hints.position = .midSentence
		}
		hints.needsLeadingSpace = !lastChar.isWhitespace && !"([{„“\"'«/-".contains(lastChar)

		// List item on the current line.
		let line = before.components(separatedBy: "\n").last ?? ""
		if let match = line.range(of: #"^\s*([-•*–]|\d{1,3}[.)])\s"#, options: .regularExpression) {
			hints.listMarker = String(line[match]).trimmingCharacters(in: .whitespaces) + " "
		}

		let words = before.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted).filter { !$0.isEmpty }
		let lower = words.map { $0.lowercased() }

		// Language: common function words.
		let german = lower.filter { germanFunctionWords.contains($0) }.count
		let english = lower.filter { englishFunctionWords.contains($0) }.count
		if german + english >= 3 {
			hints.language = german >= english ? "de" : "en"
		}

		// Formal or informal address (German).
		let informal = lower.filter { ["du", "dir", "dich", "dein", "deine", "deinen", "deinem", "deiner", "euch", "euer", "eure"].contains($0) }.count
		let formal = formalAddressCount(before)
		if formal > informal, formal > 0 { hints.address = .formal } else if informal > formal { hints.address = .informal }

		// Names and rare words: capitalised inside a sentence, with digits or
		// inner capitals, not an ordinary dictionary word.
		var seen = Set<String>()
		var previousEndsSentence = true
		var previousIsTitle = false
		for token in before.split(whereSeparator: { $0.isWhitespace }) {
			let raw = String(token)
			let afterTitle = previousIsTitle
			previousIsTitle = titles.contains(raw.trimmingCharacters(in: CharacterSet(charactersIn: ",;")).lowercased())
			let word = raw.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-.")).inverted)
				.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
			defer { previousEndsSentence = endsSentence(raw) }
			guard word.count >= 3, let first = word.first, first.isLetter else { continue }
			let hasInnerCapital = word.dropFirst().contains { $0.isUppercase }
			let hasDigit = word.contains { $0.isNumber }
			let capitalisedInside = first.isUppercase && !previousEndsSentence
			guard hasInnerCapital || hasDigit || capitalisedInside else { continue }
			let language = hints.language ?? "de"
			// A name after "Frau", "Herr", "Dr." stays a name even if it is also a word.
			if !hasInnerCapital, !hasDigit, !afterTitle, isGeneralWord(word, language) { continue }
			if germanFunctionWords.contains(word.lowercased()) || englishFunctionWords.contains(word.lowercased()) { continue }
			if ["Sie", "Ihnen", "Ihr", "Ihre", "Ihren", "Ihrem", "Ihrer"].contains(word) { continue }
			guard seen.insert(word.lowercased()).inserted else { continue }
			hints.terms.append(word)
			if hints.terms.count == maximumTerms { break }
		}
		return hints
	}

	/// Formal "Sie/Ihnen/Ihr" written capitalised inside a sentence, or "Sehr geehrte".
	static func formalAddressCount(_ text: String) -> Int {
		var count = text.contains("Sehr geehrte") ? 2 : 0
		var previousEndsSentence = true
		for token in text.split(whereSeparator: { $0.isWhitespace }) {
			let raw = String(token)
			let word = raw.trimmingCharacters(in: .punctuationCharacters)
			if !previousEndsSentence, ["Sie", "Ihnen", "Ihr", "Ihre", "Ihren", "Ihrem", "Ihrer"].contains(word) { count += 1 }
			previousEndsSentence = endsSentence(raw)
		}
		return count
	}

	/// "Dr.", "Prof.", "z.B." and similar abbreviations do not end a sentence.
	static func endsSentence(_ token: String) -> Bool {
		guard let last = token.last, ".!?:".contains(last) else { return false }
		if last == ".", abbreviations.contains(token.lowercased()) { return false }
		return true
	}

	static let titles: Set<String> = ["frau", "herr", "herrn", "dr.", "prof.", "mr.", "mrs.", "ms.", "dear", "liebe", "lieber"]

	static let abbreviations: Set<String> = [
		"dr.", "prof.", "hr.", "fr.", "frau.", "herr.", "nr.", "str.", "z.b.", "u.a.", "bzw.", "ca.", "vgl.", "evtl.", "mr.", "mrs.", "ms.", "e.g.", "i.e.",
	]

	// MARK: Deterministic use (no AI)

	/// Capitals and the leading space fit the text before the cursor.
	public static func adaptInsertion(_ text: String, hints: ContextHints) -> String {
		guard !text.isEmpty, hints.position != .empty else { return text }
		var result = text
		if let first = result.first, first.isLetter {
			let firstWord = String(result.prefix { $0.isLetter })
			switch hints.position {
			case .sentenceStart:
				result = first.uppercased() + result.dropFirst()
			case .midSentence:
				let lowered = firstWord.lowercased()
				if firstWord != lowered, germanFunctionWords.contains(lowered) || englishFunctionWords.contains(lowered),
				   !["Sie", "Ihnen", "Ihr", "Ihre", "Ihren", "Ihrem", "Ihrer", "I"].contains(firstWord) {
					result = lowered + result.dropFirst(firstWord.count)
				}
			case .empty:
				break
			}
		}
		if hints.needsLeadingSpace, let first = result.first, !".,;:!?)]}…".contains(first), !first.isWhitespace {
			result = " " + result
		}
		return result
	}

	/// Dictated words that match a term from the field (same word in other
	/// case, or the same sound and a close spelling) take its spelling.
	public static func applyTerms(_ text: String, terms: [String], isGeneralWord: (String, String) -> Bool = { _, _ in false }, language: String = "de") -> String {
		guard !terms.isEmpty else { return text }
		var output = ""
		var word = ""
		func flush() {
			guard !word.isEmpty else { return }
			output += replacement(for: word) ?? word
			word = ""
		}
		func replacement(for candidate: String) -> String? {
			for term in terms {
				if candidate == term { return nil }
				if candidate.lowercased() == term.lowercased() { return term }
				guard candidate.count >= 5, term.count >= 5, !isGeneralWord(candidate, language) else { continue }
				let sameSound = PhoneticKey.key(candidate, language: language) == PhoneticKey.key(term, language: language)
				if sameSound, StringSimilarity.normalizedLevenshtein(candidate.lowercased(), term.lowercased()) >= 0.75 {
					return term
				}
			}
			return nil
		}
		for character in text {
			if character.isLetter || character.isNumber || character == "-" {
				word.append(character)
			} else {
				flush()
				output.append(character)
			}
		}
		flush()
		return output
	}

	// MARK: Hints for the AI

	/// Short, derived hints for the system prompt; raw text only when the
	/// experimental option is on.
	public static func prompt(_ hints: ContextHints, context: AIContext, settings: ContextSettings) -> String? {
		guard settings.use != .off else { return nil }
		var lines: [String] = []
		if settings.appType || settings.use == .appOnly, let app = hints.appName ?? context.appName {
			let profile = (hints.profileName ?? context.profileName).map { " (profile \u{201C}\($0)\u{201D})" } ?? ""
			lines.append("- The text goes into \u{201C}\(app)\u{201D}\(profile).")
		}
		if settings.use == .analyzed {
			if settings.language, let language = hints.language {
				lines.append("- The surrounding text is \(language == "de" ? "German" : "English").")
			}
			if settings.address, let address = hints.address {
				lines.append(address == .formal
					? "- The surrounding text addresses the reader formally (Sie); keep that form."
					: "- The surrounding text addresses the reader informally (du); keep that form.")
			}
			if settings.continuation {
				switch hints.position {
				case .midSentence: lines.append("- The text continues a sentence that is already started.")
				case .sentenceStart: lines.append("- The text starts a new sentence.")
				case .empty: break
				}
			}
			if settings.listFormat, hints.listMarker != nil {
				lines.append("- The text is one list item; do not add a list marker.")
			}
			if settings.terms, !hints.terms.isEmpty {
				lines.append("- Spell these names and terms exactly like this: " + hints.terms.joined(separator: ", ") + ".")
			}
			if settings.sendNearbyText, let before = context.textBeforeCursor?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
				let flat = before.replacingOccurrences(of: "\n", with: " ")
				lines.append("- Text before the cursor: \u{00AB}\(String(flat.suffix(settings.characters)))\u{00BB}")
			}
		}
		guard !lines.isEmpty else { return nil }
		return """
		Context (reference only – never edit, quote, continue or answer it):
		\(lines.joined(separator: "\n"))
		"""
	}

	static let germanFunctionWords: Set<String> = [
		"der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder", "aber", "denn",
		"dass", "wenn", "weil", "als", "wie", "auch", "noch", "nicht", "schon", "dann", "so", "mit", "von", "zu", "zum",
		"zur", "bei", "nach", "für", "auf", "aus", "in", "im", "an", "am", "ist", "sind", "war", "wird", "ich", "wir",
		"er", "es", "sie", "ihr", "man", "sich", "hier", "da", "nur", "bitte", "also",
	]

	static let englishFunctionWords: Set<String> = [
		"the", "a", "an", "and", "or", "but", "so", "then", "to", "of", "in", "on", "at", "for", "with", "from", "is",
		"are", "was", "be", "it", "we", "they", "you", "he", "she", "this", "that", "not", "also", "as", "if", "when",
		"because", "please",
	]
}
