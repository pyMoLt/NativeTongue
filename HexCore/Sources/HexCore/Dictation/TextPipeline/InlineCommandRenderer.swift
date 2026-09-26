import Foundation

/// Literal mode: turns spoken punctuation/format words into mark/format tokens,
/// e.g. `Alpha Komma Beta` → word(Alpha), mark(.comma), word(Beta).
public enum InlineCommandRenderer {
	public static func render(_ tokens: [TextToken], englishCommands: Bool) -> [TextToken] {
		var output: [TextToken] = []
		var index = 0

		// Prefix commands at the very beginning of an utterance ("Überschrift …").
		let leadingWords = tokens.prefix { $0.wordText != nil }.compactMap(\.wordText)
		if let match = CommandGrammar.match(normalized(leadingWords), at: 0, in: CommandGrammar.formatPrefix, english: englishCommands),
		   match.length < tokens.count {
			output.append(.format(match.0))
			index = consumedTokenCount(tokens, words: match.length)
		}

		while index < tokens.count {
			guard tokens[index].wordText != nil else {
				output.append(tokens[index])
				index += 1
				continue
			}
			// Collect the run of word tokens starting here for multi-word matching.
			let run = tokens[index...].prefix { $0.wordText != nil }.compactMap(\.wordText)
			let words = normalized(Array(run.prefix(4)))
			if let match = CommandGrammar.match(words, at: 0, in: CommandGrammar.punctuation, english: englishCommands),
			   isWholeWordMatch(run: Array(run.prefix(match.length)), length: match.length) {
				output.append(.mark(match.0))
				index += match.length
				continue
			}
			if let match = CommandGrammar.match(words, at: 0, in: CommandGrammar.formatInline, english: englishCommands),
			   isWholeWordMatch(run: Array(run.prefix(match.length)), length: match.length) {
				output.append(.format(match.0))
				index += match.length
				continue
			}
			output.append(tokens[index])
			index += 1
		}
		return output
	}

	/// One normalized word per token keeps matching aligned with token positions.
	private static func normalized(_ words: [String]) -> [String] {
		words.map { CommandGrammar.normalizedWords($0).joined() }
	}

	/// A token like "ST-Hebung" normalizes to "sthebung" and must not match "Punkt"-style phrases partially.
	private static func isWholeWordMatch(run: [String], length: Int) -> Bool {
		run.count == length && run.allSatisfy { CommandGrammar.normalizedWords($0).count == 1 }
	}

	private static func consumedTokenCount(_ tokens: [TextToken], words: Int) -> Int {
		var seen = 0
		for (i, token) in tokens.enumerated() where token.wordText != nil {
			seen += 1
			if seen == words { return i + 1 }
		}
		return tokens.count
	}
}
