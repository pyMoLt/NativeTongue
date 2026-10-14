import Foundation

public enum StructuralCommand: String, Sendable, Equatable, CaseIterable {
	case newLine
	case newParagraph
}

public enum EditCommand: Sendable, Hashable {
	case deleteLastUtterance
	case deleteLastSentence
	case deleteLastWord
	/// „lösche die letzten drei Wörter“ (2…10).
	case deleteLastWords(Int)
	/// „ersetze X durch Y“: the last occurrence of X (case-insensitive, whole words).
	case replace(String, with: String)
	case undo
	case clearAll
}

public enum FormatCommand: String, Sendable, Equatable, CaseIterable {
	case capitalizeNext
	case allCapsNext
	case lowercaseNext
	case bullet
	case numberedItem
	case heading
	case boldStart, boldEnd
	case italicStart, italicEnd
}

public enum BoxCommand: String, Sendable, Equatable, CaseIterable {
	case transfer
	case spell
}

/// Explicitly spoken punctuation (literal mode).
public enum PunctuationMark: String, Sendable, Equatable, CaseIterable {
	case period, comma, colon, semicolon, question, exclamation
	case hyphen, dash, slash, backslash, underscore, at, ampersand, percent
	case parenOpen, parenClose, bracketOpen, bracketClose, braceOpen, braceClose
	case quoteOpen, quoteClose, singleQuoteOpen, singleQuoteClose
	case ellipsis, space

	public func glyph(language: String) -> String {
		let english = language.lowercased().hasPrefix("en")
		switch self {
		case .period: return "."
		case .comma: return ","
		case .colon: return ":"
		case .semicolon: return ";"
		case .question: return "?"
		case .exclamation: return "!"
		case .hyphen: return "-"
		case .dash: return "–"
		case .slash: return "/"
		case .backslash: return "\\"
		case .underscore: return "_"
		case .at: return "@"
		case .ampersand: return "&"
		case .percent: return "%"
		case .parenOpen: return "("
		case .parenClose: return ")"
		case .bracketOpen: return "["
		case .bracketClose: return "]"
		case .braceOpen: return "{"
		case .braceClose: return "}"
		case .quoteOpen: return english ? "\u{201C}" : "\u{201E}"
		case .quoteClose: return english ? "\u{201D}" : "\u{201C}"
		case .singleQuoteOpen: return english ? "\u{2018}" : "\u{201A}"
		case .singleQuoteClose: return english ? "\u{2019}" : "\u{2018}"
		case .ellipsis: return "…"
		case .space: return " "
		}
	}

	/// How the mark attaches to its neighbours when rendered.
	public var spacing: MarkSpacing {
		switch self {
		case .period, .comma, .colon, .semicolon, .question, .exclamation, .percent,
		     .parenClose, .bracketClose, .braceClose, .quoteClose, .singleQuoteClose, .ellipsis:
			return .closing
		case .parenOpen, .bracketOpen, .braceOpen, .quoteOpen, .singleQuoteOpen:
			return .opening
		case .hyphen, .slash, .backslash, .underscore, .at:
			return .joining
		case .dash, .ampersand:
			return .spaced
		case .space:
			return .literalSpace
		}
	}

	public var endsSentence: Bool {
		self == .period || self == .question || self == .exclamation
	}
}

public enum MarkSpacing: Sendable, Equatable {
	case closing       // "word," – no space before, space after
	case opening       // " (word" – space before, none after
	case joining       // "a-b" – no spaces
	case spaced        // "a – b"
	case literalSpace
}

/// Intermediate representation of dictated text. All pipeline stages operate on
/// tokens so spacing, capitalization and edit commands work across utterances.
public enum TextToken: Sendable, Equatable {
	case word(String)
	/// Punctuation produced by the ASR model (kept in normal mode, removed in literal mode).
	case modelMark(String, MarkSpacing)
	/// Punctuation the user dictated explicitly.
	case mark(PunctuationMark)
	case lineBreak
	case paragraphBreak
	case format(FormatCommand)

	public var wordText: String? {
		if case let .word(text) = self { return text }
		return nil
	}
}

public enum ModelTextTokenizer {
	private static let openingChars: Set<Character> = ["(", "[", "{", "„", "‚", "«", "“", "‘", "\""]
	private static let closingChars: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "“", "”", "’", "»", "\"", "…"]

	/// Splits model output into words and attached punctuation while keeping
	/// decimals ("2,5"), abbreviations with inner dots ("z.B."), hyphenated
	/// compounds ("ST-Hebungsinfarkt"), times ("10:30") and URLs intact.
	public static func tokenize(_ text: String) -> [TextToken] {
		var tokens: [TextToken] = []
		for raw in text.split(whereSeparator: { $0.isWhitespace }) {
			var chunk = Substring(raw)
			var leading: [TextToken] = []
			while let first = chunk.first, openingChars.contains(first), chunk.count > 1 || first != "\"" {
				leading.append(.modelMark(String(first), .opening))
				chunk = chunk.dropFirst()
			}
			var trailing: [TextToken] = []
			while let last = chunk.last, closingChars.contains(last) {
				// Keep an abbreviation dot like "z.B." or "Dr." with its word.
				if last == ".", isAbbreviation(chunk) { break }
				trailing.insert(.modelMark(String(last), .closing), at: 0)
				chunk = chunk.dropLast()
			}
			if chunk == "-" || chunk == "–" || chunk == "—" {
				tokens += leading
				tokens.append(.modelMark("–", .spaced))
				tokens += trailing
				continue
			}
			tokens += leading
			if !chunk.isEmpty { tokens.append(.word(String(chunk))) }
			tokens += trailing
		}
		return tokens
	}

	public static let abbreviations: Set<String> = [
		"z.b.", "z. b.", "u.a.", "bzw.", "ca.", "dr.", "prof.", "nr.", "etc.", "vs.", "e.g.", "i.e.",
		"mr.", "mrs.", "st.", "d.h.", "o.ä.", "evtl.", "ggf.", "inkl.", "zzgl.", "usw.", "vgl.", "bspw.",
		"med.", "dipl.", "mind.", "max.", "min.", "u.u.", "s.o.", "s.u.", "i.v.", "p.o.", "s.c.", "i.m.",
	]

	static func isAbbreviation(_ chunk: Substring) -> Bool {
		let lower = chunk.lowercased()
		if abbreviations.contains(lower) { return true }
		// Letter-dot-letter-dot patterns such as "z.B." or "i.v.".
		return lower.range(of: #"^([a-zäöü]\.){2,}$"#, options: .regularExpression) != nil
	}
}
