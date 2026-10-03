import Foundation

/// Drops well-known phrases Whisper-style models emit for near-silent or very
/// short audio ("Vielen Dank.", "Untertitel im Auftrag des ZDF").
public enum HallucinationFilter {
	public static let phrases: Set<String> = [
		"vielen dank", "danke", "danke schön", "dankeschön", "tschüss", "bis zum nächsten mal",
		"untertitel im auftrag des zdf", "untertitel im auftrag des zdf 2020", "untertitelung des zdf",
		"untertitel von stephanie geiges", "copyright wdr",
		"thank you", "thanks for watching", "thank you for watching", "you", "bye",
	]

	public static func shouldDrop(text: String, utteranceDurationMs: Int) -> Bool {
		guard utteranceDurationMs < 2_500 else { return false }
		let normalized = CommandGrammar.normalizedWords(text).joined(separator: " ")
		return phrases.contains(normalized)
	}

	/// Collapses decoder repetition loops ("und dann und dann und dann und dann …").
	/// Greedy Whisper decoding without temperature fallback can get stuck
	/// repeating a phrase (audit A4). A run of the same 2–8-word phrase repeated
	/// at least `minimumPhraseRepeats` times, or of one word at least
	/// `minimumWordRepeats` times, is reduced to a single occurrence. Ordinary
	/// emphasis ("sehr, sehr, sehr") stays untouched.
	public static func collapsingRepetitionLoops(
		_ text: String,
		minimumPhraseRepeats: Int = 4,
		minimumWordRepeats: Int = 5
	) -> String {
		var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
		guard tokens.count >= minimumPhraseRepeats * 2 || tokens.count >= minimumWordRepeats else { return text }
		func key(_ token: String) -> String {
			token.lowercased().trimmingCharacters(in: .punctuationCharacters)
		}
		var changed = false
		var start = 0
		while start < tokens.count {
			var collapsed = false
			for length in 1...8 where start + length * 2 <= tokens.count {
				let required = length == 1 ? minimumWordRepeats : minimumPhraseRepeats
				let phrase = tokens[start..<(start + length)].map(key)
				guard !phrase.allSatisfy(\.isEmpty) else { continue }
				var repeats = 1
				var next = start + length
				while next + length <= tokens.count,
				      tokens[next..<(next + length)].map(key) == phrase {
					repeats += 1
					next += length
				}
				if repeats >= required {
					tokens.removeSubrange((start + length)..<next)
					changed = true
					collapsed = true
					break
				}
			}
			if !collapsed { start += 1 }
		}
		return changed ? tokens.joined(separator: " ") : text
	}
}
