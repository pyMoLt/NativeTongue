import Foundation

/// Normal mode: explicit spoken code formats for prompts to coding agents.
/// Only fixed phrases trigger; ordinary sentences are left untouched.
public enum AgentFormatter {
	public static let fileExtensions: Set<String> = [
		"swift", "py", "js", "ts", "tsx", "jsx", "json", "md", "yaml", "yml", "toml", "txt", "sh", "html", "css",
		"sql", "rs", "go", "kt", "java", "c", "h", "cpp", "m", "plist", "xcodeproj", "csv",
	]

	private static let caseStyles: [([String], CaseStyle)] = [
		(["camel", "case"], .camel), (["kamel", "case"], .camel), (["camelcase"], .camel),
		(["pascal", "case"], .pascal), (["pascalcase"], .pascal),
		(["snake", "case"], .snake), (["snakecase"], .snake),
		(["kebab", "case"], .kebab), (["kebabcase"], .kebab),
	]

	enum CaseStyle { case camel, pascal, snake, kebab }

	/// Words that end a spoken identifier ("camel case user name um …" → `userName`).
	private static let identifierStopWords: Set<String> = [
		"um", "und", "oder", "in", "im", "auf", "mit", "zu", "für", "von", "an", "als", "dann", "bitte", "damit", "dass",
		"to", "and", "or", "in", "on", "with", "for", "from", "as", "then", "please", "so", "that", "the", "a",
	]

	public static func format(_ tokens: [TextToken]) -> [TextToken] {
		var output: [TextToken] = []
		var i = 0
		while i < tokens.count {
			let word = tokens[i].wordText.map(norm)

			// "<name> Punkt <ext>" → name.ext
			if let name = tokens[i].wordText,
			   let dot = tokens[safe: i + 1]?.wordText.map(norm), dot == "punkt" || dot == "dot",
			   let ext = tokens[safe: i + 2]?.wordText.map(norm), fileExtensions.contains(ext) {
				output.append(.word(name + "." + ext))
				i += 3
				continue
			}

			// "Backtick … Backtick" or "Code … Code Ende" → `…`
			if word == "backtick" || word == "backticks" {
				if let close = tokens[(i + 1)...].prefix(8).firstIndex(where: { ["backtick", "backticks"].contains($0.wordText.map(norm) ?? "") }) {
					let inner = tokens[(i + 1)..<close].compactMap(\.wordText).joined(separator: " ")
					if !inner.isEmpty {
						output.append(.word("`" + inner + "`"))
						i = close + 1
						continue
					}
				}
			}
			if word == "code", let close = codeEnd(tokens, after: i) {
				let inner = tokens[(i + 1)..<close].compactMap(\.wordText).joined(separator: " ")
				if !inner.isEmpty {
					output.append(.word("`" + inner + "`"))
					i = close + 2
					continue
				}
			}

			// Case styles
			if let (style, length) = matchCaseStyle(tokens, at: i) {
				// Explicit terminator ("… Ende"/"… end") allows up to 6 words; otherwise
				// stop at a function word and take at most 3 words.
				var parts: [String] = []
				var j = i + length
				let window = (0..<7).compactMap { tokens[safe: j + $0]?.wordText }
				if let end = window.firstIndex(where: { ["ende", "end"].contains(norm($0)) }), end > 0 {
					parts = Array(window[..<end])
					j += end + 1
				} else {
					while let next = tokens[safe: j]?.wordText, !identifierStopWords.contains(norm(next)), parts.count < 3 {
						parts.append(next)
						j += 1
					}
				}
				if !parts.isEmpty {
					output.append(.word(render(parts, style: style)))
					i = j
					continue
				}
			}

			// "Slash <word>" at the beginning → /word
			if i == 0, word == "slash", let next = tokens[safe: 1]?.wordText {
				output.append(.word("/" + next.lowercased()))
				i = 2
				continue
			}

			// "<a> Unterstrich <b>" → a_b
			if word == "unterstrich" || word == "underscore",
			   case let .word(previous)? = output.last, let next = tokens[safe: i + 1]?.wordText {
				output[output.count - 1] = .word(previous + "_" + next)
				i += 2
				continue
			}

			output.append(tokens[i])
			i += 1
		}
		return output
	}

	/// Index of "Code" in a closing "Code Ende"/"code end" within the next 8 words.
	private static func codeEnd(_ tokens: [TextToken], after start: Int) -> Int? {
		var j = start + 1
		while j + 1 < tokens.count, j - start <= 8 {
			let end = tokens[j + 1].wordText.map(norm)
			if tokens[j].wordText.map(norm) == "code", end == "ende" || end == "end" { return j }
			j += 1
		}
		return nil
	}

	private static func matchCaseStyle(_ tokens: [TextToken], at i: Int) -> (CaseStyle, Int)? {
		for (words, style) in caseStyles {
			let slice = (0..<words.count).compactMap { tokens[safe: i + $0]?.wordText.map(norm) }
			if slice == words { return (style, words.count) }
		}
		return nil
	}

	static func render(_ parts: [String], style: CaseStyle) -> String {
		let lower = parts.map { $0.lowercased() }
		switch style {
		case .camel: return lower.enumerated().map { $0.offset == 0 ? $0.element : $0.element.capitalizedFirst }.joined()
		case .pascal: return lower.map(\.capitalizedFirst).joined()
		case .snake: return lower.joined(separator: "_")
		case .kebab: return lower.joined(separator: "-")
		}
	}

	/// Lowercased letters/digits only. Deliberately no filler stripping: "um" is a real word here.
	private static func norm(_ word: String) -> String {
		String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
	}
}

extension String {
	var capitalizedFirst: String {
		guard let first else { return self }
		return first.uppercased() + dropFirst()
	}

	var lowercasedFirst: String {
		guard let first else { return self }
		return first.lowercased() + dropFirst()
	}
}
