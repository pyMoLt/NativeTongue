import Foundation

/// Literal mode: turns spoken punctuation/format words into mark/format tokens,
/// e.g. `Alpha Komma Beta` → word(Alpha), mark(.comma), word(Beta).
public enum InlineCommandRenderer {
	/// - Parameters:
	///   - allowedMarks: nil = every spoken punctuation command; otherwise only these.
	///   - includeFormat: also apply inline format commands ("großschreiben", "fett an").
	///   - pauseBeforeWord: silence before each word token in ms (from word
	///     timestamps), when known; see `isSpokenAsWord`.
	public static func render(
		_ tokens: [TextToken],
		englishCommands: Bool,
		allowedMarks: Set<PunctuationMark>? = nil,
		includeFormat: Bool = true,
		pauseBeforeWord: [Int?]? = nil,
		commandPauseMs: Int = 450,
		language: String = "de"
	) -> [TextToken] {
		let english = language.lowercased().hasPrefix("en")
		var output: [TextToken] = []
		var index = 0
		/// Word tokens before `index`.
		func wordIndex(_ tokenIndex: Int) -> Int { tokens[..<tokenIndex].filter { $0.wordText != nil }.count }

		// Prefix commands at the very beginning of an utterance ("Überschrift …").
		let leadingWords = tokens.prefix { $0.wordText != nil }.compactMap(\.wordText)
		if includeFormat, let match = CommandGrammar.match(normalized(leadingWords), at: 0, in: CommandGrammar.formatPrefix, english: englishCommands),
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
			// „Klammer-auf“: an ASR spelling with a hyphen is one token.
			if let word = tokens[index].wordText, word.contains("-"),
			   let mark = CommandGrammar.isolated(CommandGrammar.normalizedWords(word), in: CommandGrammar.punctuation, english: englishCommands),
			   allowedMarks?.contains(mark) ?? true {
				output.append(.mark(mark))
				index += 1
				continue
			}
			// Collect the run of word tokens starting here for multi-word matching.
			let run = tokens[index...].prefix { $0.wordText != nil }.compactMap(\.wordText)
			let words = normalized(Array(run.prefix(4)))
			if let match = CommandGrammar.match(words, at: 0, in: CommandGrammar.punctuation, english: englishCommands),
			   allowedMarks?.contains(match.0) ?? true,
			   isWholeWordMatch(run: Array(run.prefix(match.length)), length: match.length),
			   !isSpokenAsWord(previous: output.last, pause: pauseBeforeWord.flatMap { $0[safe: wordIndex(index)] ?? nil },
			                   commandPauseMs: commandPauseMs, english: english) {
				output.append(.mark(match.0))
				index += match.length
				continue
			}
			if includeFormat, let match = CommandGrammar.match(words, at: 0, in: CommandGrammar.formatInline, english: englishCommands),
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

	/// Articles, prepositions and determiners before a punctuation word make it
	/// a word („einen Punkt“, „das Komma“, „im Doppelpunkt“, „the comma“),
	/// unless the timestamps show a command pause before it. Personal pronouns
	/// do not count („sagte er Doppelpunkt“ stays a command). „das Wort Punkt“
	/// always stays a word.
	static let germanWordMarkers: Set<String> = [
		"der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
		"kein", "keine", "keinen", "keinem", "keiner", "mein", "meine", "meinen", "dein", "deine", "sein", "seine", "seinen",
		"ihr", "ihre", "ihren", "unser", "unsere", "dieser", "diese", "diesen", "diesem", "dieses", "jeder", "jede", "jeden", "jedem",
		"im", "am", "beim", "vom", "zum", "zur", "ins", "ans", "aufs", "in", "an", "auf", "mit", "nach", "vor", "hinter", "über",
		"unter", "ohne", "durch", "für", "um", "bis", "neben", "zwischen", "hinterm", "überm", "unterm",
	]
	static let englishWordMarkers: Set<String> = [
		"a", "an", "the", "this", "that", "these", "those", "every", "each", "my", "your", "his", "its", "our", "their",
		"of", "on", "at", "with", "without", "by", "for", "to", "from", "into", "after", "before", "in",
	]
	static let escapeWords: Set<String> = ["wort", "word", "begriff", "zeichen"]

	static func isSpokenAsWord(previous: TextToken?, pause: Int?, commandPauseMs: Int, english: Bool = false) -> Bool {
		guard let word = previous?.wordText else { return false }
		// Plain lowercase: the command normalizer drops fillers such as „um“.
		let lower = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
		if escapeWords.contains(lower) { return true }
		guard (english ? englishWordMarkers : germanWordMarkers).contains(lower) else { return false }
		if let pause, pause >= commandPauseMs { return false }
		return true
	}

	/// Pause before each word token of `ModelTextTokenizer.tokenize(text)`,
	/// given one gap per whitespace-separated piece of `text`.
	public static func pausesPerWordToken(text: String, gaps: [Int?]) -> [Int?]? {
		let pieces = text.split(whereSeparator: { $0.isWhitespace })
		guard pieces.count == gaps.count else { return nil }
		var result: [Int?] = []
		for (piece, gap) in zip(pieces, gaps) {
			let words = ModelTextTokenizer.tokenize(String(piece)).filter { $0.wordText != nil }.count
			guard words > 0 else { continue }
			result.append(gap)
			result += Array(repeating: 0, count: words - 1)
		}
		return result
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
