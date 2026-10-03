import Foundation

/// Joins spelled-out words inside a dictation (normal and literal, AI on or off):
/// - "schreibe groß a b c", "buchstabiere x y z", "capital a b c" → "ABC" / "XYZ"
/// - "a wie Anton p wie Paula i wie Ida" (two or more pairs) → "API"
///
/// Only explicit triggers or letter–alphabet-word pairs whose initials agree
/// are rewritten, so ordinary words like the English article "a" stay.
public enum SpelledWordRenderer {
	private static let upperTriggers: [[String]] = [
		["schreibe", "groß"], ["schreib", "groß"], ["schreibe", "gross"], ["in", "großbuchstaben"],
		["buchstabiere"], ["buchstabiert"], ["capital"], ["capitals"], ["spell"], ["spelled"],
	]
	private static let lowerTriggers: [[String]] = [["schreibe", "klein"], ["schreib", "klein"], ["lowercase"]]
	private static let pairWords: Set<String> = ["wie", "for", "as"]

	public static func render(_ tokens: [TextToken]) -> [TextToken] {
		var output: [TextToken] = []
		var index = 0
		while index < tokens.count {
			if let (word, consumed, dropPrevious) = triggeredRun(tokens, at: index) {
				if dropPrevious, let last = output.last, last.wordText.map(normalized) == "bitte" { output.removeLast() }
				output.append(.word(word))
				index += consumed
				continue
			}
			if let (word, consumed) = alphabetPairs(tokens, at: index) {
				output.append(.word(word))
				index += consumed
				continue
			}
			output.append(tokens[index])
			index += 1
		}
		return output
	}

	// MARK: - Triggered runs

	private static func triggeredRun(_ tokens: [TextToken], at start: Int) -> (String, Int, Bool)? {
		for (triggers, upper) in [(upperTriggers, true), (lowerTriggers, false)] {
			for trigger in triggers {
				guard wordsMatch(tokens, at: start, trigger) else { continue }
				let afterTrigger = start + trigger.count
				let (letters, consumed) = letterRun(tokens, at: afterTrigger)
				guard letters.count >= 2 else { continue }
				let word = upper ? letters.uppercased() : letters.lowercased()
				return (word, trigger.count + consumed, true)
			}
		}
		return nil
	}

	/// Single letters or spelling-alphabet words, optionally separated by model commas.
	private static func letterRun(_ tokens: [TextToken], at start: Int) -> (String, Int) {
		var letters = ""
		var index = start
		var consumed = 0
		while index < tokens.count {
			if case let .modelMark(glyph, _) = tokens[index], glyph == "," { index += 1; continue }
			guard let word = tokens[index].wordText.map(normalized), let letter = letter(for: word) else { break }
			letters += letter
			index += 1
			consumed = index - start
		}
		return (letters, consumed)
	}

	// MARK: - Alphabet pairs

	private static func alphabetPairs(_ tokens: [TextToken], at start: Int) -> (String, Int)? {
		var letters = ""
		var index = start
		var consumed = 0
		var pairs = 0
		while index + 2 < tokens.count {
			guard let first = tokens[index].wordText.map(normalized), first.count == 1, first.first!.isLetter,
			      let link = tokens[index + 1].wordText.map(normalized), pairWords.contains(link),
			      let name = tokens[index + 2].wordText.map(normalized),
			      let spelled = SpellingInterpreter.letter(forAlphabetWord: name), spelled == first
			else { break }
			letters += first.uppercased()
			index += 3
			pairs += 1
			consumed = index - start
			if index < tokens.count, case let .modelMark(glyph, _) = tokens[index], glyph == "," { index += 1 }
		}
		return pairs >= 2 ? (letters, consumed) : nil
	}

	// MARK: - Helpers

	private static func wordsMatch(_ tokens: [TextToken], at start: Int, _ words: [String]) -> Bool {
		guard start + words.count <= tokens.count else { return false }
		for (offset, expected) in words.enumerated() {
			guard tokens[start + offset].wordText.map(normalized) == expected else { return false }
		}
		return true
	}

	private static func letter(for word: String) -> String? {
		if word.count == 1, word.first!.isLetter { return word }
		return SpellingInterpreter.letter(forAlphabetWord: word)
	}

	private static func normalized(_ word: String) -> String {
		word.lowercased().trimmingCharacters(in: .punctuationCharacters)
	}
}
