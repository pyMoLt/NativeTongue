import Foundation

/// Applies the same literal-output contract to every backend. Decoder masks
/// and model flags are optimizations; this deterministic pass is the fallback.
public enum EngineResultNormalizer {
	public static func apply(_ result: EngineResult, punctuation: PunctuationPolicy) -> EngineResult {
		guard punctuation == .suppressed else { return result }
		var clean = result
		clean.text = LiteralNormalizer.stripAutomaticMarks(from: result.text)
		clean.words = result.words.compactMap { word in
			let text = LiteralNormalizer.stripAutomaticMarks(from: word.text)
			guard !text.isEmpty else { return nil }
			return EngineWord(text: text, start: word.start, end: word.end, confidence: word.confidence)
		}
		clean.punctuationWasSuppressed = true
		return clean
	}
}
