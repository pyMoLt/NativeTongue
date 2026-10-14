import Foundation

/// Edit commands on plain text that NativeTongue inserted itself (Streaming:
/// typed text of the session; normal insertion: the last pasted dictation).
/// The text is kept in segments, one per utterance, so „streich das“ removes
/// exactly the last utterance. Never touches anything beyond these segments.
public enum TextEditPlanner {
	/// The segments after `edit`, or nil when there is nothing to change.
	public static func apply(_ edit: EditCommand, to segments: [String]) -> [String]? {
		var segments = segments
		while let last = segments.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.removeLast() }
		guard !segments.isEmpty else { return nil }
		let joined = segments.joined()
		switch edit {
		case .deleteLastUtterance, .undo:
			segments.removeLast()
			return segments
		case .clearAll:
			return []
		case .deleteLastWord:
			return truncate(segments, to: removingLastWords(1, from: joined))
		case let .deleteLastWords(count):
			return truncate(segments, to: removingLastWords(max(count, 1), from: joined))
		case .deleteLastSentence:
			return truncate(segments, to: removingLastSentence(from: joined))
		case let .replace(old, new):
			guard let range = lastRange(of: old, in: joined) else { return nil }
			var text = joined
			text.replaceSubrange(range, with: new)
			return [text]
		}
	}

	/// Keystrokes turning `old` into `new`: characters to delete at the end, then text to type.
	public static func keystrokes(from old: String, to new: String) -> (delete: Int, insert: String) {
		var prefix = 0
		for (a, b) in zip(old, new) {
			guard a == b else { break }
			prefix += 1
		}
		return (old.count - prefix, String(new.dropFirst(prefix)))
	}

	/// Whether `phrase` occurs as whole words in `text` (case-insensitive).
	public static func contains(_ phrase: String, in text: String) -> Bool {
		lastRange(of: phrase, in: text) != nil
	}

	// MARK: - Helpers

	private static func truncate(_ segments: [String], to length: Int) -> [String] {
		var result: [String] = []
		var remaining = length
		for segment in segments where remaining > 0 {
			if segment.count <= remaining {
				result.append(segment)
				remaining -= segment.count
			} else {
				result.append(String(segment.prefix(remaining)))
				remaining = 0
			}
		}
		return result
	}

	private static func isWordCharacter(_ character: Character) -> Bool {
		character.isLetter || character.isNumber || character == "-" || character == "'" || character == "’"
	}

	/// Length (characters) of `text` after removing the last `count` words
	/// together with the punctuation and spaces that follow them.
	static func removingLastWords(_ count: Int, from text: String) -> Int {
		var characters = Array(text)
		for _ in 0..<count {
			while let last = characters.last, !isWordCharacter(last) { characters.removeLast() }
			guard !characters.isEmpty else { break }
			while let last = characters.last, isWordCharacter(last) { characters.removeLast() }
		}
		while let last = characters.last, last == " " || last == "\t" { characters.removeLast() }
		return characters.count
	}

	/// Length of `text` without its last sentence (the text after the previous
	/// sentence end, line break or paragraph break).
	static func removingLastSentence(from text: String) -> Int {
		var characters = Array(text)
		while let last = characters.last, last.isWhitespace || ".!?…".contains(last) { characters.removeLast() }
		while let last = characters.last, !(".!?…".contains(last) || last.isNewline) { characters.removeLast() }
		while let last = characters.last, last == " " || last == "\t" { characters.removeLast() }
		return characters.count
	}

	/// Last whole-word occurrence of `phrase`, case-insensitive, any whitespace between words.
	public static func lastRange(of phrase: String, in text: String) -> Range<String.Index>? {
		let words = phrase.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
		guard !words.isEmpty else { return nil }
		let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
		let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
		guard let last = matches.last else { return nil }
		return Range(last.range, in: text)
	}
}
