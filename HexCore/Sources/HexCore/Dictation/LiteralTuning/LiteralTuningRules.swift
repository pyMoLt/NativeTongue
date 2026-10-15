import Foundation

/// Text and utterance rules of `LiteralTuning`. Pure functions, no engine access.
public enum LiteralTuningRules {
	// MARK: Cleanup

	static let edgeHallucinations: [[String]] = [
		["thank", "you", "for", "watching"], ["thanks", "for", "watching"], ["thank", "you"], ["you"], ["bye"],
		["untertitel", "im", "auftrag", "des", "zdf"], ["untertitelung", "des", "zdf"], ["copyright", "wdr"],
	]

	/// Removes CJK characters (Qwen hallucinates „嗯。“, „个。“ on silence).
	public static func removingCJK(_ text: String) -> String {
		let kept = text.unicodeScalars.filter { scalar in
			switch scalar.value {
			case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0xAC00...0xD7AF:
				return false
			default:
				return true
			}
		}
		let cleaned = String(String.UnicodeScalarView(kept))
		guard cleaned != text else { return text }
		return cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
	}

	/// Number of whitespace pieces to drop at the start (`atStart`) or end of `text`.
	static func hallucinatedEdge(_ text: String, atStart: Bool) -> Int {
		let pieces = text.split(whereSeparator: { $0.isWhitespace }).map { CommandGrammar.normalizedWords(String($0)).joined() }
		for phrase in edgeHallucinations where phrase.count < pieces.count {
			let slice = atStart ? Array(pieces.prefix(phrase.count)) : Array(pieces.suffix(phrase.count))
			if slice == phrase { return phrase.count }
		}
		return 0
	}

	private static func pieces(_ text: String) -> [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

	/// CJK characters anywhere, hallucinated phrases at the very start and end of the recording.
	/// A whole utterance made of such a phrase is left to `HallucinationFilter`.
	public static func cleanEdges(_ aligned: [AlignedUtterance]) -> [AlignedUtterance] {
		var result = aligned.map { item -> AlignedUtterance in
			let cleaned = removingCJK(item.text)
			guard cleaned != item.text else { return item }
			return AlignedUtterance(utterance: item.utterance, text: cleaned, language: item.language,
			                        wordGapsMs: pieces(cleaned).count == item.wordGapsMs?.count ? item.wordGapsMs : nil)
		}
		if let index = result.firstIndex(where: { !$0.text.isEmpty }) {
			let item = result[index]
			let drop = hallucinatedEdge(item.text, atStart: true)
			if drop > 0 {
				result[index] = AlignedUtterance(utterance: item.utterance, text: pieces(item.text).dropFirst(drop).joined(separator: " "),
				                                 language: item.language, wordGapsMs: item.wordGapsMs.map { Array($0.dropFirst(drop)) })
			}
		}
		if let index = result.lastIndex(where: { !$0.text.isEmpty }) {
			let item = result[index]
			let drop = hallucinatedEdge(item.text, atStart: false)
			if drop > 0 {
				result[index] = AlignedUtterance(utterance: item.utterance, text: pieces(item.text).dropLast(drop).joined(separator: " "),
				                                 language: item.language, wordGapsMs: item.wordGapsMs.map { Array($0.dropLast(drop)) })
			}
		}
		return result
	}

	// MARK: Structural commands

	private static func structuralPhrases(englishCommands: Bool) -> [[String]] {
		CommandGrammar.structural.map(\.0).filter { englishCommands || !$0.english }.map(\.words)
	}

	private static func bulletPhrases(englishCommands: Bool) -> [[String]] {
		CommandGrammar.formatPrefix.filter { $0.1 == .bullet && (englishCommands || !$0.0.english) }.map(\.0.words)
	}

	/// „… Neuer“ ⏸ „Absatz …“ → „…“ ⏸ „Neuer Absatz …“: the command keeps the pause before it.
	public static func joinSplitStructural(_ aligned: [AlignedUtterance], englishCommands: Bool) -> [AlignedUtterance] {
		guard aligned.count > 1 else { return aligned }
		let phrases = structuralPhrases(englishCommands: englishCommands).filter { $0.count > 1 }
		var result = aligned
		for index in 0 ..< result.count - 1 {
			let previous = pieces(result[index].text)
			let next = pieces(result[index + 1].text)
			let prevWords = previous.map { CommandGrammar.normalizedWords($0).joined() }
			let nextWords = next.map { CommandGrammar.normalizedWords($0).joined() }
			var move = 0
			for phrase in phrases {
				for k in 1 ..< phrase.count where k < prevWords.count {
					let m = phrase.count - k
					guard m <= nextWords.count, Array(prevWords.suffix(k)) == Array(phrase.prefix(k)),
					      Array(nextWords.prefix(m)) == Array(phrase.suffix(m)) else { continue }
					move = max(move, k)
				}
			}
			guard move > 0 else { continue }
			let a = result[index], b = result[index + 1]
			result[index] = AlignedUtterance(utterance: a.utterance, text: previous.dropLast(move).joined(separator: " "), language: a.language,
			                                 wordGapsMs: a.wordGapsMs.map { Array($0.dropLast(move)) })
			var gaps: [Int?]?
			if let nextGaps = b.wordGapsMs, nextGaps.count == next.count {
				// The moved words start the utterance; the old first word now follows them.
				gaps = [b.utterance.pauseBeforeMs] + Array(repeating: Int?.some(0), count: move - 1) + [Int?.some(0)] + nextGaps.dropFirst()
			}
			result[index + 1] = AlignedUtterance(utterance: b.utterance, text: (Array(previous.suffix(move)) + next).joined(separator: " "),
			                                     language: b.language, wordGapsMs: gaps)
		}
		return result
	}

	/// Splits an utterance before a structural command spoken after a pause
	/// (word gaps ≥ `commandPauseMs`, or anywhere without timings when
	/// `withoutTimings`) and before a bullet command at any position.
	public static func splitAtStructural(
		_ aligned: [AlignedUtterance],
		commandPauseMs: Int,
		englishCommands: Bool,
		pauseBefore: Bool,
		withoutTimings: Bool,
		bullets: Bool
	) -> [AlignedUtterance] {
		let structural = pauseBefore ? structuralPhrases(englishCommands: englishCommands) : []
		let bulletWords = bullets ? bulletPhrases(englishCommands: englishCommands) : []
		let markPhrases = CommandGrammar.punctuation.map(\.0).filter { englishCommands || !$0.english }.map(\.words)
		var result: [AlignedUtterance] = []
		var nextID = (aligned.map(\.utterance.id).max() ?? 0) + 1_000
		for item in aligned {
			let words = pieces(item.text)
			let normalized = words.map { CommandGrammar.normalizedWords($0).joined() }
			let gaps = item.wordGapsMs.flatMap { $0.count == words.count ? $0 : nil }
			var cuts: [(index: Int, gap: Int)] = []
			for index in 1 ..< max(1, words.count) {
				let gap = gaps?[index] ?? nil
				if bulletWords.contains(where: { Array(normalized[index...].prefix($0.count)) == $0 }) {
					cuts.append((index, gap ?? 0))
				} else if structural.contains(where: { Array(normalized[index...].prefix($0.count)) == $0 }) {
					// Right after a spoken mark („Doppelpunkt Neuer Absatz“) it is a command without a pause.
					let afterMark = markPhrases.contains { $0.count <= index && Array(normalized[(index - $0.count) ..< index]) == $0 }
					if let gap, gap >= commandPauseMs {
						cuts.append((index, gap))
					} else if afterMark {
						cuts.append((index, max(gap ?? 0, commandPauseMs)))
					} else if gaps == nil, withoutTimings {
						cuts.append((index, commandPauseMs))
					}
				}
			}
			guard !cuts.isEmpty else { result.append(item); continue }
			let bounds = [0] + cuts.map(\.index) + [words.count]
			let range = item.utterance.range
			for part in 0 ..< bounds.count - 1 {
				let lo = bounds[part], hi = bounds[part + 1]
				let sampleLo = range.lowerBound + range.count * lo / words.count
				let sampleHi = range.lowerBound + range.count * hi / words.count
				let before = part == 0 ? item.utterance.pauseBeforeMs : cuts[part - 1].gap
				let after = part == bounds.count - 2 ? item.utterance.pauseAfterMs : cuts[part].gap
				var partGaps = gaps.map { Array($0[lo ..< hi]) }
				if part > 0 { partGaps?[0] = nil }
				let id = part == 0 ? item.utterance.id : nextID
				if part > 0 { nextID += 1 }
				result.append(AlignedUtterance(
					utterance: Utterance(id: id, range: sampleLo ..< max(sampleLo + 1, sampleHi), pauseBeforeMs: before, pauseAfterMs: after),
					text: words[lo ..< hi].joined(separator: " "), language: item.language, wordGapsMs: partGaps))
			}
		}
		return result
	}

	// MARK: Numbers

	static let decimalUnits = "mg|g|kg|µg|mcg|ml|l|mmol|mol|%|cm|mm|m|km|Grad|°C|°|Milligramm|Gramm|Milliliter|Prozent|Liter"
	private static let decimalPattern = try? NSRegularExpression(
		pattern: "\\b(\\d{1,3}) (\\d{1,2})(?= (?:\(decimalUnits))\\b)", options: [.caseInsensitive])

	private static let spokenDecimalPattern = try? NSRegularExpression(pattern: "\\b(\\d{1,3}) (?:Komma|comma) (\\d{1,2})\\b", options: [.caseInsensitive])

	/// „2 5 mg“ → „2,5 mg“: the decoder may not write the comma inside a number.
	/// „2 Komma 5“ (digits around a spoken comma) → „2,5“.
	public static func repairDecimals(_ text: String) -> String {
		var text = text
		if let regex = spokenDecimalPattern {
			text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1,$2")
		}
		guard let regex = decimalPattern else { return text }
		return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1,$2")
	}

	/// 1250 → „1.250“.
	public static func grouped(_ value: Int) -> String {
		var digits = Array(String(value))
		var index = digits.count - 3
		while index > 0 { digits.insert(".", at: index); index -= 3 }
		return String(digits)
	}

	/// Digits the engine wrote itself: „1250 €“ / „12500“ → grouped (German).
	public static func groupDigitTokens(_ tokens: [TextToken], language: String) -> [TextToken] {
		guard !language.lowercased().hasPrefix("en") else { return tokens }
		var output = tokens
		let currency: Set<String> = ["€", "euro", "$", "dollar", "chf", "franken"]
		for index in output.indices {
			guard case let .word(text) = output[index], text.count >= 4, text.allSatisfy(\.isNumber), let value = Int(text) else { continue }
			let next = output[safe: index + 1]?.wordText?.lowercased()
			if value >= 10_000 || (next.map(currency.contains) ?? false) { output[index] = .word(grouped(value)) }
		}
		return output
	}
}
