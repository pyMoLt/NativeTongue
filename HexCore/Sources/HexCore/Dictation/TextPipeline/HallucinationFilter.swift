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
}
