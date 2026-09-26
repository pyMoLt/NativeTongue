import Foundation

/// Controls how explicitly spoken formatting commands are handled.
public enum DictationMode: String, Codable, CaseIterable, Equatable, Sendable {
	case normal
	case literal

	public var displayName: String {
		switch self {
		case .normal: "Normal dictation"
		case .literal: "Literal punctuation"
		}
	}
}

/// Word-level timings returned by an ASR backend. These are used only to gate
/// structural voice commands; they never affect transcript text directly.
public struct TranscriptWordTiming: Equatable, Sendable {
	public let word: String
	public let startTime: TimeInterval
	public let endTime: TimeInterval

	public init(word: String, startTime: TimeInterval, endTime: TimeInterval) {
		self.word = word
		self.startTime = startTime
		self.endTime = endTime
	}
}

/// A conservative, deterministic formatter for explicitly spoken commands.
/// It never rewrites ordinary words. The normal mode only handles line/paragraph
/// commands; literal mode additionally converts explicitly spoken punctuation.
public enum SpokenCommandFormatter {
	private struct Command {
		let phrases: [String]
		let marker: String
		let requiresPause: Bool

		init(phrases: [String], marker: String, requiresPause: Bool = false) {
			self.phrases = phrases
			self.marker = marker
			self.requiresPause = requiresPause
		}
	}

	private static let normalCommands = [
		Command(phrases: ["neuer absatz", "neuen absatz", "neue absatz", "new paragraph", "paragraph break"], marker: "__HEX_SPOKEN_PARAGRAPH__", requiresPause: true),
		Command(phrases: ["neue zeile", "neuer zeile", "new line", "line break"], marker: "__HEX_SPOKEN_LINE__", requiresPause: true)
	]

	private static let literalCommands = [
		Command(phrases: ["eckige klammer auf", "öffnende eckige klammer", "open square bracket", "square bracket open"], marker: "__HEX_SPOKEN_SQUARE_OPEN__"),
		Command(phrases: ["eckige klammer zu", "schließende eckige klammer", "close square bracket", "square bracket close"], marker: "__HEX_SPOKEN_SQUARE_CLOSE__"),
		Command(phrases: ["geschweifte klammer auf", "öffnende geschweifte klammer", "open brace", "left curly brace"], marker: "__HEX_SPOKEN_CURLY_OPEN__"),
		Command(phrases: ["geschweifte klammer zu", "schließende geschweifte klammer", "close brace", "right curly brace"], marker: "__HEX_SPOKEN_CURLY_CLOSE__"),
		Command(phrases: ["anführungszeichen auf", "öffnendes anführungszeichen", "open quote", "quote open", "begin quote"], marker: "__HEX_SPOKEN_QUOTE_OPEN__"),
		Command(phrases: ["anführungszeichen zu", "schließendes anführungszeichen", "close quote", "quote close", "end quote"], marker: "__HEX_SPOKEN_QUOTE_CLOSE__"),
		Command(phrases: ["klammer auf", "öffnende klammer", "open parenthesis", "left parenthesis"], marker: "__HEX_SPOKEN_PAREN_OPEN__"),
		Command(phrases: ["klammer zu", "schließende klammer", "close parenthesis", "right parenthesis"], marker: "__HEX_SPOKEN_PAREN_CLOSE__"),
		Command(phrases: ["neuer absatz", "neuen absatz", "neue absatz", "new paragraph", "paragraph break"], marker: "__HEX_SPOKEN_PARAGRAPH__", requiresPause: true),
		Command(phrases: ["neue zeile", "neuer zeile", "new line", "line break"], marker: "__HEX_SPOKEN_LINE__", requiresPause: true),
		Command(phrases: ["gedankenstrich", "em dash"], marker: "__HEX_SPOKEN_EM_DASH__"),
		Command(phrases: ["bindestrich", "hyphen"], marker: "__HEX_SPOKEN_HYPHEN__"),
		Command(phrases: ["schrägstrich", "slash"], marker: "__HEX_SPOKEN_SLASH__"),
		Command(phrases: ["backslash", "umgekehrter schrägstrich"], marker: "__HEX_SPOKEN_BACKSLASH__"),
		Command(phrases: ["unterstrich", "underscore"], marker: "__HEX_SPOKEN_UNDERSCORE__"),
		Command(phrases: ["at zeichen", "at sign"], marker: "__HEX_SPOKEN_AT__"),
		Command(phrases: ["ausrufezeichen", "exclamation mark", "exclamation point"], marker: "__HEX_SPOKEN_EXCLAMATION__"),
		Command(phrases: ["fragezeichen", "question mark"], marker: "__HEX_SPOKEN_QUESTION__"),
		Command(phrases: ["doppelpunkt", "colon"], marker: "__HEX_SPOKEN_COLON__"),
		Command(phrases: ["semikolon", "semicolon"], marker: "__HEX_SPOKEN_SEMICOLON__"),
		Command(phrases: ["komma", "comma"], marker: "__HEX_SPOKEN_COMMA__"),
		Command(phrases: ["punkt", "period", "full stop"], marker: "__HEX_SPOKEN_PERIOD__")
	]

	public static func apply(
		_ text: String,
		mode: DictationMode,
		wordTimings: [TranscriptWordTiming] = [],
		minimumCommandPause: TimeInterval = 0.45
	) -> String {
		guard mode == .normal || mode == .literal else { return text }
		let commands = mode == .literal ? literalCommands : normalCommands
		let alignedWords = align(text, with: wordTimings)

		struct Match {
			let range: NSRange
			let marker: String
			let wordCount: Int
			let requiresPause: Bool
		}
		let nsText = text as NSString
		var matches: [Match] = []

		for command in commands {
			for phrase in command.phrases {
			let phrasePattern = NSRegularExpression.escapedPattern(for: phrase)
				.replacingOccurrences(of: "\\ ", with: "\\s+")
			let pattern = "(?<![\\p{L}\\p{N}_])\(phrasePattern)(?![\\p{L}\\p{N}_])"
			guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
			let wordCount = phrase.split(whereSeparator: { $0.isWhitespace }).count
			for result in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
				matches.append(Match(
					range: result.range,
					marker: command.marker,
					wordCount: wordCount,
					requiresPause: command.requiresPause
				))
			}
		}
		}

		// Resolve overlaps by keeping the longest phrase at each location.
		matches.sort {
			if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
			return $0.range.length > $1.range.length
		}
		var accepted: [Match] = []
		var lastAcceptedEnd = 0
		for match in matches {
			guard match.range.location >= lastAcceptedEnd else { continue }
			if match.requiresPause {
				guard let alignedWords else { continue }
				let prefix = nsText.substring(to: match.range.location)
				let startWord = lexicalWords(in: prefix).count
				let endWord = startWord + match.wordCount
				guard endWord <= alignedWords.count else { continue }
				let pauseBefore = hasCommandPause(beforeWord: startWord, timings: alignedWords, threshold: minimumCommandPause)
				let pauseAfter = hasCommandPause(beforeWord: endWord, timings: alignedWords, threshold: minimumCommandPause)
				guard pauseBefore || pauseAfter else {
					continue
				}
			}
			accepted.append(match)
			lastAcceptedEnd = NSMaxRange(match.range)
		}

		var output = text
		for match in accepted.reversed() {
			guard let range = Range(match.range, in: output) else { continue }
			output.replaceSubrange(range, with: match.marker)
		}

		return renderMarkers(in: normalizeASRCommas(aroundMarkersIn: output))
	}

	private static func align(_ text: String, with timings: [TranscriptWordTiming]) -> [TranscriptWordTiming]? {
		let words = lexicalWords(in: text)
		let lexicalTimings = timings.filter { !normalized($0.word).isEmpty }
		guard words.count == lexicalTimings.count else { return nil }
		for (word, timing) in zip(words, lexicalTimings) where word != normalized(timing.word) {
			return nil
		}
		return lexicalTimings
	}

	private static func lexicalWords(in text: String) -> [String] {
		text
			.split(whereSeparator: { $0.isWhitespace })
			.map { normalized(String($0)) }
			.filter { !$0.isEmpty }
	}

	private static func normalized(_ word: String) -> String {
		let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
		return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
	}

	private static func hasCommandPause(
		beforeWord index: Int,
		timings: [TranscriptWordTiming],
		threshold: TimeInterval
	) -> Bool {
		// Text boundaries are not evidence of an audible pause. Only compare
		// gaps between timed lexical words.
		guard index > 0, index < timings.count else { return false }
		return timings[index].startTime - timings[index - 1].endTime >= threshold
	}

	/// Whisper may emit punctuation as standalone tokens around a spoken command
	/// (for example, a comma before and after “colon”). Those commas are ASR
	/// punctuation, not part of the command, so remove only commas touching a
	/// recognized command marker before rendering it. Explicit comma commands
	/// are still markers at this stage and are preserved.
	private static func normalizeASRCommas(aroundMarkersIn text: String) -> String {
		let markers = Set((normalCommands + literalCommands).map(\.marker))
		return markers.reduce(text) { output, marker in
			let escapedMarker = NSRegularExpression.escapedPattern(for: marker)
			let pattern = "\\s*(?:,\\s*)*\(escapedMarker)(?:\\s*,)*\\s*"
			return output.replacingOccurrences(of: pattern, with: marker, options: .regularExpression)
		}
	}

	private static func renderMarkers(in text: String) -> String {
		var output = text
		let punctuation: [(String, String)] = [
			("COMMA", ","), ("PERIOD", "."), ("COLON", ":"),
			("SEMICOLON", ";"), ("QUESTION", "?"), ("EXCLAMATION", "!")
		]

		for (name, glyph) in punctuation {
			let marker = "__HEX_SPOKEN_\(name)__"
			output = output.replacingOccurrences(of: "\\s*\(marker)\\s*", with: glyph + " ", options: .regularExpression)
		}

		let replacements = [
			("PARAGRAPH", "\n\n"), ("LINE", "\n"),
			("SQUARE_OPEN", "["), ("SQUARE_CLOSE", "]"),
			("CURLY_OPEN", "{"), ("CURLY_CLOSE", "}"),
			("PAREN_OPEN", "("), ("PAREN_CLOSE", ")"),
			("QUOTE_OPEN", "“"), ("QUOTE_CLOSE", "”"),
			("EM_DASH", " — "), ("HYPHEN", "-"),
			("SLASH", "/"), ("BACKSLASH", "\\"), ("UNDERSCORE", "_"), ("AT", "@")
		]

		for (name, glyph) in replacements {
			let marker = "__HEX_SPOKEN_\(name)__"
			let replacementGlyph = NSRegularExpression.escapedTemplate(for: glyph)
			if name == "PARAGRAPH" || name == "LINE" {
				output = output.replacingOccurrences(of: "[ \\t]*\(NSRegularExpression.escapedPattern(for: marker))[ \\t]*", with: replacementGlyph, options: .regularExpression)
			} else if name.hasSuffix("_OPEN") || name == "QUOTE_OPEN" {
				output = output.replacingOccurrences(of: "[ \\t]*\(NSRegularExpression.escapedPattern(for: marker))[ \\t]*", with: " " + replacementGlyph, options: .regularExpression)
			} else if name.hasSuffix("_CLOSE") || name == "QUOTE_CLOSE" {
				output = output.replacingOccurrences(of: "[ \\t]*\(NSRegularExpression.escapedPattern(for: marker))[ \\t]*", with: replacementGlyph + " ", options: .regularExpression)
			} else if name == "EM_DASH" {
				output = output.replacingOccurrences(of: "\\s*\(NSRegularExpression.escapedPattern(for: marker))\\s*", with: replacementGlyph, options: .regularExpression)
			} else {
				output = output.replacingOccurrences(of: "\\s*\(NSRegularExpression.escapedPattern(for: marker))\\s*", with: replacementGlyph, options: .regularExpression)
			}
		}

		output = output.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
		output = output.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
		return output.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
