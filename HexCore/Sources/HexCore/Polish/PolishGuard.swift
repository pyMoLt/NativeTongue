import Foundation

/// A difference between the original dictation and the AI result that the
/// safety check considers risky (plan 2.5, section 3.3).
public struct PolishGuardIssue: Equatable, Sendable {
	public enum Kind: String, Equatable, Sendable {
		case empty
		case lengthChanged
		case numberChanged
		case termChanged
		case negationChanged
		case codeChanged
	}

	public let kind: Kind
	/// The original token that went missing or changed (empty for length).
	public let detail: String

	public init(kind: Kind, detail: String = "") {
		self.kind = kind
		self.detail = detail
	}

	/// Short text for tooltips in the dictation box.
	public var explanation: String {
		switch kind {
		case .empty: "The AI returned no text."
		case .lengthChanged: "The AI changed the length a lot."
		case .numberChanged: "Number or dose changed: \(detail)"
		case .termChanged: "Term changed: \(detail)"
		case .negationChanged: "A negation was added or removed."
		case .codeChanged: "Code or file name changed: \(detail)"
		}
	}
}

/// Compares the text before and after the language model.
public enum PolishGuard {
	public static func check(
		original: String,
		result: String,
		strictness: GuardStrictness,
		lengthTolerancePercent: Int,
		protectedTerms: [String] = []
	) -> [PolishGuardIssue] {
		let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return [PolishGuardIssue(kind: .empty)] }
		var issues: [PolishGuardIssue] = []

		if strictness != .keyFacts {
			// Compare content characters, ignoring fillers and spelling
			// instructions that a correct clean-up removes ("schreibe groß a b c" → "ABC").
			let before = max(0, contentLength(original) - convertedCommandLength(original: original, result: trimmed))
			let after = contentLength(trimmed)
			let change = abs(Double(after - before)) / Double(max(before, 1)) * 100
			// Very short texts legitimately change a lot ("äh ja" → "Ja.").
			if change > Double(lengthTolerancePercent), words(original).count >= 6 {
				issues.append(PolishGuardIssue(kind: .lengthChanged))
			}
			if strictness == .strict, !issues.contains(where: { $0.kind == .lengthChanged }),
			   hasOmittedSentence(original: original, result: trimmed) {
				issues.append(PolishGuardIssue(kind: .lengthChanged))
			}
		}
		guard strictness != .lengthOnly else { return issues }

		let originalNumbers = numbers(in: original)
		let resultNumbers = numbers(in: trimmed)
		if strictness == .strict {
			for (value, count) in originalNumbers where (resultNumbers[value] ?? 0) != count {
				issues.append(PolishGuardIssue(kind: .numberChanged, detail: value))
			}
			for (value, _) in resultNumbers where originalNumbers[value] == nil {
				issues.append(PolishGuardIssue(kind: .numberChanged, detail: value))
			}
		} else {
			for value in originalNumbers.keys where resultNumbers[value] == nil {
				issues.append(PolishGuardIssue(kind: .numberChanged, detail: value))
			}
		}

		let lowerResult = trimmed.lowercased()
		let lowerOriginal = original.lowercased()
		for term in protectedTerms {
			let key = term.lowercased()
			guard !key.isEmpty, lowerOriginal.contains(key) else { continue }
			if !lowerResult.contains(key) {
				issues.append(PolishGuardIssue(kind: .termChanged, detail: term))
			}
		}

		let negationsBefore = negationCount(original)
		let negationsAfter = negationCount(trimmed)
		if strictness == .strict ? negationsBefore != negationsAfter : (negationsBefore > 0 && negationsAfter == 0) {
			issues.append(PolishGuardIssue(kind: .negationChanged))
		}

		for token in codeTokens(in: original) where !trimmed.contains(token) {
			issues.append(PolishGuardIssue(kind: .codeChanged, detail: token))
		}
		return issues
	}

	// MARK: - Extraction

	static func words(_ text: String) -> [Substring] {
		text.split(whereSeparator: { $0.isWhitespace })
	}

	private static let ignoredForLength: Set<String> = [
		"äh", "ähm", "ehm", "hm", "hmm", "uh", "um", "erm", "mhm",
		"schreibe", "schreib", "groß", "gross", "klein", "buchstabiere", "buchstabiert", "buchstabieren", "bitte", "wie",
		"capital", "uppercase", "lowercase", "spell", "spelled", "write", "as", "in",
	]

	/// Letters and digits of the words that carry content.
	static func contentLength(_ text: String) -> Int {
		let tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
		let spelling = SpellingInterpreter.alphabetWords
		return tokens.reduce(0) { total, token in
			if ignoredForLength.contains(token) || (spelling.contains(token) && token.count > 1) { return total }
			return total + token.count
		}
	}

	/// Spoken formatting words disappear when the model turns them into marks.
	/// Discount only those occurrences whose mark is present in the result;
	/// literal mentions that remain in both texts still contribute to length.
	static func convertedCommandLength(original: String, result: String) -> Int {
		let commands: [(phrase: String, mark: String)] = [
			("klammer auf", "("), ("klammer zu", ")"),
			("neuer absatz", "\n\n"), ("neue zeile", "\n"),
			("doppelpunkt", ":"), ("semikolon", ";"),
			("fragezeichen", "?"), ("ausrufezeichen", "!"),
			("bindestrich", "-"), ("komma", ","), ("punkt", "."),
		]
		var reduction = 0
		for (phrase, mark) in commands where result.contains(mark) {
			let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: "\\ ", with: #"\s+"#) + #"\b"#
			guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
			let before = regex.numberOfMatches(in: original, range: NSRange(original.startIndex..., in: original))
			let after = regex.numberOfMatches(in: result, range: NSRange(result.startIndex..., in: result))
			let removed = max(0, before - after)
			reduction += removed * phrase.filter(\.isLetter).count
		}
		return reduction
	}

	/// A long dictation can lose a complete sentence without crossing the
	/// overall 25% length threshold. Content words must still be represented.
	static func hasOmittedSentence(original: String, result: String) -> Bool {
		let common: Set<String> = [
			"aber", "alle", "auch", "beim", "dass", "diese", "dieser", "eine", "einen", "einer", "erst", "für", "hier", "oder", "sind", "über", "und", "wird",
			"about", "after", "also", "from", "have", "into", "that", "their", "them", "then", "there", "these", "this", "with", "would",
		]
		func contentWords(_ text: String) -> Set<String> {
			Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
				.filter { $0.count >= 4 && !common.contains($0) && !ignoredForLength.contains($0) })
		}
		let output = contentWords(result)
		for sentence in original.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
			let words = contentWords(sentence)
			guard words.count >= 6 else { continue }
			let retained = words.intersection(output).count
			if Double(retained) / Double(words.count) < 0.45 { return true }
		}
		return false
	}

	/// Numbers with an optional directly following unit, normalised
	/// ("2,5 mg" and "2,5mg" → "2,5 mg"; "20" → "20").
	static func numbers(in text: String) -> [String: Int] {
		let pattern = #"(\d+(?:[.,]\d+)*)\s?(%|°C|°|mg|µg|mcg|g|kg|ml|mL|l|IE|I\.E\.|mmol|mol|mmHg|cm|mm|m|h|min|s)?(?![\p{L}\d])"#
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
		var result: [String: Int] = [:]
		let range = NSRange(text.startIndex..., in: text)
		for match in regex.matches(in: text, range: range) {
			guard let numberRange = Range(match.range(at: 1), in: text) else { continue }
			var key = String(text[numberRange])
			if let unitRange = Range(match.range(at: 2), in: text) { key += " " + text[unitRange] }
			result[key, default: 0] += 1
		}
		return result
	}

	private static let negations: Set<String> = [
		"nicht", "kein", "keine", "keinen", "keinem", "keiner", "keines", "nie", "niemals", "nichts", "weder",
		"not", "no", "never", "none", "nothing", "neither", "nor",
	]

	static func negationCount(_ text: String) -> Int {
		let lower = text.lowercased()
		let tokens = lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
		let contractions = lower.components(separatedBy: .whitespacesAndNewlines).filter { $0.contains("n't") }.count
		return tokens.filter(negations.contains).count + contractions
	}

	/// `backtick spans` and file names such as ContentView.swift.
	static func codeTokens(in text: String) -> [String] {
		var tokens: [String] = []
		let patterns = [#"`[^`\n]+`"#, #"\b[\w-]+\.(?:swift|py|js|ts|tsx|jsx|json|md|txt|yml|yaml|toml|sh|rb|go|rs|java|kt|c|h|cpp|m|html|css|sql|csv|pdf|docx|xlsx)\b"#]
		for pattern in patterns {
			guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
			for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
				if let range = Range(match.range, in: text) { tokens.append(String(text[range])) }
			}
		}
		return tokens
	}
}

/// Splits long dictations so a small model never has to rewrite pages at once.
public enum PolishChunker {
	/// Paragraphs are kept whole when possible; long ones split at sentence ends.
	public static func chunks(_ text: String, maxWords: Int = 160) -> [String] {
		guard PolishGuard.words(text).count > maxWords else { return [text] }
		var chunks: [String] = []
		var current: [String] = []
		var count = 0
		func flush() {
			if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
			current = []
			count = 0
		}
		for paragraph in text.components(separatedBy: "\n\n") {
			let paragraphWords = PolishGuard.words(paragraph).count
			if paragraphWords > maxWords {
				flush()
				var sentenceChunk = ""
				var sentenceWords = 0
				for sentence in sentences(paragraph) {
					let words = PolishGuard.words(sentence).count
					if sentenceWords + words > maxWords, !sentenceChunk.isEmpty {
						chunks.append(sentenceChunk.trimmingCharacters(in: .whitespaces))
						sentenceChunk = ""
						sentenceWords = 0
					}
					sentenceChunk += sentence
					sentenceWords += words
				}
				if !sentenceChunk.isEmpty { chunks.append(sentenceChunk.trimmingCharacters(in: .whitespaces)) }
				continue
			}
			if count + paragraphWords > maxWords { flush() }
			current.append(paragraph)
			count += paragraphWords
		}
		flush()
		return chunks
	}

	static func sentences(_ text: String) -> [String] {
		var result: [String] = []
		var current = ""
		for character in text {
			current.append(character)
			if ".!?".contains(character) {
				result.append(current)
				current = ""
			}
		}
		if !current.isEmpty { result.append(current) }
		return result
	}

	/// Re-joins chunk results with the separators the input used.
	public static func join(_ parts: [String], original: String) -> String {
		parts.joined(separator: original.contains("\n\n") ? "\n\n" : " ")
	}
}
