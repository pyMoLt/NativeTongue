import Foundation

/// Turns engine text deltas into text that is safe to type right away, using
/// the same rules as the dictation pipeline: spoken punctuation ("Komma",
/// "Klammer auf"), line breaks, numbers and units ("zwei Komma fünf
/// Milligramm" → "2,5 mg"), code formatting and vocabulary aliases.
///
/// Typed text cannot be taken back, so words that may still turn into a
/// command or a value are held back until the next word decides it — or until
/// a speech pause releases them.
public struct StreamingTextProcessor: Sendable {
	public struct Options: Sendable, Equatable {
		public var keepPunctuation: Bool
		public var commands: StreamingVoiceCommands
		/// Lowercased known misrecognition → correct spelling (one or more words).
		public var aliases: [String: String]
		public var formatNumbers: Bool
		public var codeFormatting: Bool
		public var language: String
		public var englishCommands: Bool
		/// nil = all spoken punctuation; otherwise only these marks.
		public var allowedMarks: Set<PunctuationMark>?

		public init(
			keepPunctuation: Bool = true,
			commands: StreamingVoiceCommands = .off,
			aliases: [String: String] = [:],
			formatNumbers: Bool = false,
			codeFormatting: Bool = false,
			language: String = "de",
			englishCommands: Bool = true,
			allowedMarks: Set<PunctuationMark>? = nil
		) {
			self.keepPunctuation = keepPunctuation
			self.commands = commands
			self.aliases = aliases
			self.formatNumbers = formatNumbers
			self.codeFormatting = codeFormatting
			self.language = language
			self.englishCommands = englishCommands
			self.allowedMarks = allowedMarks
		}

		/// Settings → processor options.
		public init(settings: StreamingSettings, language: String?, englishCommands: Bool, aliases: [String: String]) {
			let basic = settings.punctuationMode == .literal && settings.literalScope == .basic
			self.init(
				keepPunctuation: settings.punctuationMode != .literal,
				commands: settings.punctuationMode == .automatic ? settings.voiceCommands : (basic ? .punctuationOnly : .all),
				aliases: settings.lexiconCorrection ? aliases : [:],
				formatNumbers: settings.formatNumbers,
				codeFormatting: settings.codeFormatting,
				language: language ?? "de",
				englishCommands: englishCommands,
				allowedMarks: basic ? StreamingLiteralScope.basicMarks : nil
			)
		}
	}

	public var options: Options
	private var pending = ""
	/// The last released text ended a sentence through a dictated mark or break.
	private var capitalizeNext = false
	/// The last released text ended with "(", a quote opener or a line break.
	private var attachNext = false
	/// The last released token was a dictated mark or break: a model mark at
	/// the start of the next piece is its echo.
	private var lastWasDictated = false

	public init(options: Options) {
		self.options = options
	}

	/// Text not yet released (shown as the pending tail in the pill).
	public var heldBack: String { pending }

	/// Feeds a delta; returns text that can be typed now.
	public mutating func push(_ delta: String) -> String {
		pending += delta
		let boundary = releaseBoundary(pending)
		guard boundary > pending.startIndex else { return "" }
		var (ready, space) = Self.splitTrailingWhitespace(String(pending[..<boundary]))
		// The space after the last released word waits for the next word: a
		// following "Komma"/"Punkt" must attach without it.
		var heldMark = ""
		if options.keepPunctuation, options.commands == .all || options.commands == .punctuationOnly,
		   let last = ready.last, ",.;:!?".contains(last) {
			// A model mark may be the echo of a command in the next words ("Alpha," + "Komma").
			heldMark = String(last)
			ready.removeLast()
		}
		pending = heldMark + space + String(pending[boundary...])
		return transform(ready)
	}

	static func splitTrailingWhitespace(_ text: String) -> (String, String) {
		let space = String(text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
		return (String(text.dropLast(space.count)), space)
	}

	/// During a speech pause: releases held words unless they may start a
	/// line-break command that the next words could complete.
	public mutating func releaseHeldWord() -> String? {
		let trimmed = pending.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return nil }
		let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
		if aliasPrefixLength(words) > 0 { return nil }
		if options.commands != .off, Self.trailingCommandStart(trimmed) != nil, Self.isLineBreakStart(trimmed) {
			return nil
		}
		let (ready, space) = Self.splitTrailingWhitespace(pending)
		pending = space
		return transform(ready)
	}

	/// Releases everything at the end of a segment or session.
	public mutating func flush() -> String {
		defer { pending = "" }
		return transform(pending)
	}

	// MARK: - Hold-back

	/// Index up to which `text` can be released: before the unfinished last
	/// word and before trailing words that may still become a command or value.
	func releaseBoundary(_ text: String) -> String.Index {
		var words: [(word: String, start: String.Index)] = []
		var index = text.startIndex
		while index < text.endIndex {
			while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
			guard index < text.endIndex else { break }
			let start = index
			while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
			words.append((String(text[start..<index]), start))
		}
		guard !words.isEmpty else { return text.endIndex }
		var held = text.last?.isWhitespace == true ? 0 : 1
		let complete = words.dropLast(held).map(\.word)
		held += trailingHoldCount(Array(complete))
		guard held > 0 else { return text.endIndex }
		guard held < words.count else { return text.startIndex }
		return words[words.count - held].start
	}

	/// How many of the trailing complete words to keep back.
	func trailingHoldCount(_ words: [String]) -> Int {
		var count = aliasPrefixLength(words)
		if options.commands != .off {
			count = max(count, Self.commandPrefixLength(words, english: options.englishCommands, includePunctuation: options.commands == .all || options.commands == .punctuationOnly))
		}
		if options.formatNumbers {
			let english = options.language.lowercased().hasPrefix("en")
			var numeric = 0
			for word in words.reversed() {
				let clean = word.trimmingCharacters(in: .punctuationCharacters)
				guard !clean.isEmpty, SpokenNumberFormatter.mayContinueValue(clean, english: english) else { break }
				numeric += 1
				if numeric == 8 { break }
			}
			count = max(count, numeric)
		}
		return count
	}

	/// Keep an alias prefix until the next word settles whether it is a match.
	private func aliasPrefixLength(_ words: [String]) -> Int {
		guard !words.isEmpty else { return 0 }
		let lower = words.map { $0.lowercased() }
		var best = 0
		for alias in options.aliases.keys {
			let parts = alias.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
			guard parts.count > 1 else { continue }
			for length in 1..<min(parts.count, lower.count + 1) {
				if Array(lower.suffix(length)) == Array(parts.prefix(length)) { best = max(best, length) }
			}
		}
		return best
	}

	/// Length of the longest suffix of `words` that is a proper prefix of a
	/// multi-word command ("Klammer" → "Klammer auf", "neuer" → "neuer Absatz").
	static func commandPrefixLength(_ words: [String], english: Bool, includePunctuation: Bool) -> Int {
		let normalized = words.map { CommandGrammar.normalizedWords($0).joined() }
		var phrases = CommandGrammar.structural.map(\.0)
		if includePunctuation {
			phrases += CommandGrammar.punctuation.map(\.0) + CommandGrammar.formatInline.map(\.0)
		}
		phrases = phrases.filter { english || !$0.english }
		var best = 0
		guard !normalized.isEmpty else { return 0 }
		for length in 1...min(3, normalized.count) {
			let suffix = Array(normalized.suffix(length))
			if phrases.contains(where: { $0.words.count > length && Array($0.words.prefix(length)) == suffix }) {
				best = length
			}
		}
		return best
	}

	static func trailingCommandStart(_ text: String) -> Int? {
		let words = text.split(separator: " ").map(String.init)
		let length = commandPrefixLength(words, english: true, includePunctuation: false)
		return length > 0 ? length : nil
	}

	static func isLineBreakStart(_ text: String) -> Bool {
		trailingCommandStart(text) != nil
	}

	// MARK: - Transform

	mutating func transform(_ text: String) -> String {
		guard !text.isEmpty else { return "" }
		let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !core.isEmpty else { return attachNext ? "" : text }
		var leading = attachNext ? "" : String(text.prefix { $0.isWhitespace })
		let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())

		let original = ModelTextTokenizer.tokenize(core)
		var tokens = original
		if !options.aliases.isEmpty {
			tokens = Self.replaceAliases(tokens, aliases: options.aliases)
		}
		if !options.keepPunctuation {
			tokens = tokens.filter { if case .modelMark = $0 { return false } else { return true } }
		}
		if options.formatNumbers {
			tokens = SpokenNumberFormatter.format(tokens, language: options.language)
		}
		if options.commands == .lineBreaksOnly || options.commands == .all {
			tokens = Self.renderLineBreaks(tokens, english: options.englishCommands)
		}
		if options.commands == .all || options.commands == .punctuationOnly {
			tokens = InlineCommandRenderer.render(
				tokens,
				englishCommands: options.englishCommands,
				allowedMarks: options.allowedMarks,
				includeFormat: options.commands == .all
			)
			// A model mark next to a dictated one is the model's echo of it ("Komma," → ",,").
			if lastWasDictated {
				var removed = false
				while let first = tokens.first, case .modelMark = first { tokens.removeFirst(); removed = true }
				// ". Alpha" lost its mark: the word still needs its space.
				if removed, leading.isEmpty, !attachNext { leading = " " }
			}
			let removedOpeningEcho: Bool = {
				guard tokens.count > 1,
				      case let .modelMark(glyph, _) = tokens[0], glyph == ".",
				      case .mark(.parenOpen) = tokens[1] else { return false }
				return true
			}()
			tokens = Self.dropEchoedModelMarks(tokens)
			if removedOpeningEcho, leading.isEmpty, !attachNext { leading = " " }
			if let last = tokens.last { lastWasDictated = Self.isDictated(last) }
		}
		if options.codeFormatting {
			tokens = AgentFormatter.format(tokens)
		}

		// Nothing to format: type the text exactly as recognised.
		guard tokens != original || capitalizeNext else {
			let output = leading + core + trailing
			attachNext = Self.opens(output)
			return output
		}

		// Capitalise after dictated sentence ends; keep the model's casing otherwise.
		var shaped: [TextToken] = capitalizeNext ? [.format(.capitalizeNext)] : []
		for token in tokens {
			shaped.append(token)
			if Self.endsSentence(token) { shaped.append(.format(.capitalizeNext)) }
		}
		capitalizeNext = tokens.last.map(Self.endsSentence) ?? false

		// The assembler trims breaks at the edges; a piece may start or end with one.
		var leadingBreaks = ""
		while let first = shaped.first, let glyph = Self.breakGlyph(first) ?? (Self.isFormat(first) && shaped.dropFirst().first.flatMap(Self.breakGlyph) != nil ? "" : nil) {
			leadingBreaks += glyph
			shaped.removeFirst()
		}
		var trailingBreaks = ""
		while let last = shaped.last, Self.breakGlyph(last) != nil || (Self.isFormat(last) && shaped.dropLast().last.flatMap(Self.breakGlyph) != nil) {
			if let glyph = Self.breakGlyph(last) { trailingBreaks = glyph + trailingBreaks }
			shaped.removeLast()
		}
		let rendered = leadingBreaks + Assembler.render(shaped, options: AssemblerOptions(language: options.language, mode: .streaming)) + trailingBreaks
		guard !rendered.isEmpty else { return "" }
		let startsAttached = rendered.first.map { ".,;:!?)]}”“…%\n-_/@".contains($0) } ?? false
		let endsOpen = Self.opens(rendered)
		let output = (startsAttached ? "" : leading) + rendered + (endsOpen ? "" : trailing)
		attachNext = Self.opens(output)
		return output
	}

	/// Text after which the next word attaches without a space.
	static func opens(_ text: String) -> Bool {
		guard let last = text.last else { return false }
		return "([{„\n/-_@".contains(last)
	}

	/// Models often write the spoken command as a mark too ("Komma," / "Fragezeichen.").
	/// A model mark is dropped next to a dictated sentence/clause mark or break; a
	/// model comma is dropped next to any dictated mark. "Klammer zu." keeps its period.
	static func dropEchoedModelMarks(_ tokens: [TextToken]) -> [TextToken] {
		let clauseMarks: Set<PunctuationMark> = [.period, .comma, .colon, .semicolon, .question, .exclamation]
		func dictated(_ token: TextToken?, modelGlyph: String, before: Bool) -> Bool {
			switch token {
			// "Satz. neuer Absatz" keeps its period; "neuer Absatz. Erster" drops the echo.
			case .lineBreak, .paragraphBreak: return before
			case let .mark(mark):
				// A spoken opening bracket continues the clause. Models often end
				// the preceding chunk with a speculative period before hearing it.
				if !before, mark == .parenOpen, modelGlyph == "." { return true }
				return clauseMarks.contains(mark) || modelGlyph == ","
			default: return false
			}
		}
		var output: [TextToken] = []
		for (index, token) in tokens.enumerated() {
			if case let .modelMark(glyph, _) = token,
			   dictated(index > 0 ? tokens[index - 1] : nil, modelGlyph: glyph, before: true)
			   || dictated(index + 1 < tokens.count ? tokens[index + 1] : nil, modelGlyph: glyph, before: false) {
				continue
			}
			output.append(token)
		}
		return output
	}

	static func isDictated(_ token: TextToken) -> Bool {
		switch token {
		case .mark, .lineBreak, .paragraphBreak: true
		default: false
		}
	}

	static func breakGlyph(_ token: TextToken) -> String? {
		switch token {
		case .lineBreak: "\n"
		case .paragraphBreak: "\n\n"
		default: nil
		}
	}

	static func isFormat(_ token: TextToken) -> Bool {
		if case .format = token { return true }
		return false
	}

	static func endsSentence(_ token: TextToken) -> Bool {
		switch token {
		case let .mark(mark): mark.endsSentence
		case .lineBreak, .paragraphBreak: true
		default: false
		}
	}

	/// "neue Zeile" / "neuer Absatz" anywhere in the text → break tokens.
	static func renderLineBreaks(_ tokens: [TextToken], english: Bool) -> [TextToken] {
		var output: [TextToken] = []
		var index = 0
		while index < tokens.count {
			let run = tokens[index...].prefix { $0.wordText != nil }.compactMap(\.wordText)
			let words = run.prefix(3).map { CommandGrammar.normalizedWords($0).joined() }
			if !words.isEmpty, let match = CommandGrammar.match(Array(words), at: 0, in: CommandGrammar.structural, english: english) {
				// A model mark right before the command belongs to the text; drop one right after.
				output.append(match.0 == .newParagraph ? .paragraphBreak : .lineBreak)
				index += match.length
				if index < tokens.count, case .modelMark = tokens[index] { index += 1 }
				continue
			}
			output.append(tokens[index])
			index += 1
		}
		return output
	}

	static func replaceWords(in text: String, _ lookup: (String) -> String?) -> String {
		var output = ""
		var word = ""
		func flushWord() {
			if !word.isEmpty { output += lookup(word) ?? word }
			word = ""
		}
		for character in text {
			if character.isLetter || character.isNumber || character == "-" {
				word.append(character)
			} else {
				flushWord()
				output.append(character)
			}
		}
		flushWord()
		return output
	}

	/// Longest exact alias first; model punctuation forms a phrase boundary.
	static func replaceAliases(_ tokens: [TextToken], aliases: [String: String]) -> [TextToken] {
		let phrases = aliases.compactMap { key, replacement -> ([String], String)? in
			let words = key.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
			return words.count > 1 ? (words, replacement) : nil
		}.sorted { $0.0.count > $1.0.count }
		var result: [TextToken] = []
		var index = 0
		while index < tokens.count {
			if let phrase = phrases.first(where: { words, _ in
				guard index + words.count <= tokens.count else { return false }
				return zip(words, tokens[index..<(index + words.count)]).allSatisfy { expected, token in
					token.wordText?.lowercased() == expected
				}
			}) {
				result += ModelTextTokenizer.tokenize(phrase.1)
				index += phrase.0.count
				continue
			}
			if case let .word(word) = tokens[index] {
				result.append(.word(replaceWords(in: word) { aliases[$0.lowercased()] }))
			} else {
				result.append(tokens[index])
			}
			index += 1
		}
		return result
	}
}
