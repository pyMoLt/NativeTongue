import Foundation

/// Literal mode: removes punctuation the ASR model added on its own, so only
/// explicitly spoken punctuation ends up in the text. Decimals, times,
/// abbreviations, hyphenated compounds and URLs survive because the tokenizer
/// keeps them inside word tokens.
public enum LiteralNormalizer {
	public static func normalize(_ tokens: [TextToken]) -> [TextToken] {
		tokens.compactMap { token in
			switch token {
			case .modelMark:
				return nil
			case let .word(text):
				let stripped = stripDanglingQuotes(text)
				return stripped.isEmpty ? nil : .word(stripped)
			default:
				return token
			}
		}
	}

	private static func stripDanglingQuotes(_ word: String) -> String {
		let quotes = CharacterSet(charactersIn: "\"„“”‚‘’«»")
		return word.trimmingCharacters(in: quotes)
	}
}
