import Foundation

public enum OutputFormat: String, Codable, Sendable, Equatable, CaseIterable {
	case plainText
	case markdown
	case richText   // rendered like markdown here; the dictation box converts to attributed text
}

public struct AssemblerOptions: Sendable, Equatable {
	public var language: String
	public var mode: DictationMode
	public var format: OutputFormat

	public init(language: String = "de", mode: DictationMode = .literal, format: OutputFormat = .plainText) {
		self.language = language
		self.mode = mode
		self.format = format
	}
}

/// Renders tokens to text: spacing around marks, line/paragraph breaks,
/// sentence-start capitalization and explicit format commands.
public enum Assembler {
	private enum PendingCase { case capitalize, upper, lower }

	public static func render(_ tokens: [TextToken], options: AssemblerOptions = AssemblerOptions()) -> String {
		var out = ""
		var needsSpace = false
		var capitalizeNext = true
		var pendingCase: PendingCase?
		var numbered = 0
		let markup = options.format != .plainText

		func trimTrailingSpaces() {
			while out.last == " " { out.removeLast() }
		}
		func spaceIfNeeded() {
			if needsSpace, let last = out.last, last != "\n", last != " " { out.append(" ") }
		}
		func startLine() {
			trimTrailingSpaces()
			if let last = out.last, last != "\n" { out.append("\n") }
			needsSpace = false
		}

		func append(glyph: String, spacing: MarkSpacing) {
			switch spacing {
			case .closing:
				trimTrailingSpaces()
				out += glyph
				needsSpace = true
			case .opening:
				spaceIfNeeded()
				out += glyph
				needsSpace = false
			case .joining:
				trimTrailingSpaces()
				out += glyph
				needsSpace = false
			case .spaced:
				trimTrailingSpaces()
				if !out.isEmpty, out.last != "\n" { out += " " }
				out += glyph
				needsSpace = true
			case .literalSpace:
				out += " "
				needsSpace = false
			}
		}

		for token in tokens {
			switch token {
			case var .word(text):
				spaceIfNeeded()
				switch pendingCase {
				case .capitalize: text = text.capitalizedFirst
				case .upper: text = text.uppercased()
				case .lower: text = text.lowercasedFirst
				// Normal mode keeps the model's casing (identifiers like `userName` must survive).
				case nil: if capitalizeNext && options.mode == .literal { text = text.capitalizedFirst }
				}
				pendingCase = nil
				capitalizeNext = false
				out += text
				needsSpace = true

			case let .mark(mark):
				append(glyph: mark.glyph(language: options.language), spacing: mark.spacing)
				if mark.endsSentence { capitalizeNext = true }

			case let .modelMark(glyph, spacing):
				append(glyph: glyph, spacing: spacing)
				if [".", "?", "!"].contains(glyph) { capitalizeNext = true }

			case .lineBreak:
				trimTrailingSpaces()
				out.append("\n")
				needsSpace = false
				capitalizeNext = true

			case .paragraphBreak:
				trimTrailingSpaces()
				if out.hasSuffix("\n\n") {
					// already a paragraph boundary
				} else if out.hasSuffix("\n") {
					out.append("\n")
				} else if !out.isEmpty {
					out.append("\n\n")
				}
				needsSpace = false
				capitalizeNext = true

			case let .format(command):
				switch command {
				case .capitalizeNext: pendingCase = .capitalize
				case .allCapsNext: pendingCase = .upper
				case .lowercaseNext: pendingCase = .lower
				case .bullet:
					startLine(); out += "- "; capitalizeNext = true
				case .numberedItem:
					numbered += 1; startLine(); out += "\(numbered). "; capitalizeNext = true
				case .heading:
					startLine(); if markup { out += "# " }; capitalizeNext = true
				case .boldStart where markup: spaceIfNeeded(); out += "**"; needsSpace = false
				case .boldEnd where markup: trimTrailingSpaces(); out += "**"; needsSpace = true
				case .italicStart where markup: spaceIfNeeded(); out += "*"; needsSpace = false
				case .italicEnd where markup: trimTrailingSpaces(); out += "*"; needsSpace = true
				default: break
				}
			}
		}

		trimTrailingSpaces()
		return out.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
