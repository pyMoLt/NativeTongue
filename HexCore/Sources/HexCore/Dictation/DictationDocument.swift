import Foundation

/// The text being dictated before it is inserted. Each entry is one utterance
/// (or one command) so "streich das" can remove exactly the last utterance.
/// Value type with a snapshot history for undo.
public struct DictationDocument: Sendable, Equatable {
	public struct Entry: Sendable, Equatable {
		public let utteranceID: Int?
		public var tokens: [TextToken]
		/// Automatic lexicon replacements in this entry (shown in the dictation box).
		public var corrections: [LexiconCorrection]

		public init(utteranceID: Int?, tokens: [TextToken], corrections: [LexiconCorrection] = []) {
			self.utteranceID = utteranceID
			self.tokens = tokens
			self.corrections = corrections
		}
	}

	public private(set) var entries: [Entry] = []
	private var history: [[Entry]] = []
	/// Edit commands that found nothing to edit in this document; the dictation
	/// box applies them to text from earlier dictations.
	public private(set) var unappliedEdits: [EditCommand] = []
	/// Box voice commands („Text übertragen“, „buchstabieren“) in spoken order.
	public private(set) var boxCommands: [BoxCommand] = []

	public init() {}

	public var tokens: [TextToken] { entries.flatMap(\.tokens) }
	public var isEmpty: Bool { tokens.isEmpty }
	public var corrections: [LexiconCorrection] { entries.flatMap(\.corrections) }

	public func render(_ options: AssemblerOptions) -> String {
		Assembler.render(tokens, options: options)
	}

	public mutating func append(utteranceID: Int?, tokens: [TextToken], corrections: [LexiconCorrection] = []) {
		guard !tokens.isEmpty else { return }
		snapshot()
		entries.append(Entry(utteranceID: utteranceID, tokens: tokens, corrections: corrections))
	}

	public mutating func record(_ command: BoxCommand) {
		boxCommands.append(command)
	}

	public mutating func apply(_ command: EditCommand) {
		guard !entries.isEmpty || (command == .undo && !history.isEmpty) else {
			unappliedEdits.append(command)
			return
		}
		switch command {
		case .undo:
			if let previous = history.popLast() { entries = previous }
		case .clearAll:
			snapshot()
			entries.removeAll()
		case .deleteLastUtterance:
			guard !entries.isEmpty else { return }
			snapshot()
			let removed = entries.removeLast()
			// The last utterance finished a sentence that began in an earlier
			// utterance (thinking pause mid-sentence): remove the whole sentence.
			if let last = removed.tokens.last(where: { $0.wordText != nil || isSentenceBoundary($0) }), isSentenceBoundary(last),
			   let flat = flatten(), let lastRemaining = flat.last, !isSentenceBoundary(lastRemaining.token) {
				var cut = flat.count
				while cut > 0, !isSentenceBoundary(flat[cut - 1].token) { cut -= 1 }
				var kept = flat
				kept.removeSubrange(cut...)
				rebuild(from: kept)
			}
		case .deleteLastWord:
			guard var flat = flatten(), let lastWord = flat.lastIndex(where: { $0.token.wordText != nil }) else { return }
			snapshot()
			flat.removeSubrange(lastWord...)
			rebuild(from: flat)
		case .deleteLastSentence:
			guard var flat = flatten() else { return }
			// Skip a trailing sentence terminator and breaks, then cut back to the previous one.
			var end = flat.count
			while end > 0, isSentenceBoundary(flat[end - 1].token) { end -= 1 }
			var start = end
			while start > 0, !isSentenceBoundary(flat[start - 1].token) { start -= 1 }
			guard start < flat.count else { return }
			snapshot()
			flat.removeSubrange(start...)
			rebuild(from: flat)
		}
	}

	/// Replaces the whole content (used when the user edits text in the dictation box).
	public mutating func replaceAll(with tokens: [TextToken]) {
		snapshot()
		entries = tokens.isEmpty ? [] : [Entry(utteranceID: nil, tokens: tokens)]
	}

	// MARK: - Helpers

	private mutating func snapshot() {
		history.append(entries)
		if history.count > 100 { history.removeFirst() }
	}

	private struct Located { let entry: Int; let token: TextToken }

	private func flatten() -> [Located]? {
		let flat = entries.enumerated().flatMap { index, entry in entry.tokens.map { Located(entry: index, token: $0) } }
		return flat.isEmpty ? nil : flat
	}

	private mutating func rebuild(from flat: [Located]) {
		var rebuilt: [Entry] = []
		for (index, entry) in entries.enumerated() {
			let kept = flat.filter { $0.entry == index }.map(\.token)
			if !kept.isEmpty { rebuilt.append(Entry(utteranceID: entry.utteranceID, tokens: kept, corrections: entry.corrections)) }
		}
		entries = rebuilt
	}

	private func isSentenceBoundary(_ token: TextToken) -> Bool {
		switch token {
		case let .mark(mark): return mark.endsSentence
		case let .modelMark(glyph, _): return [".", "?", "!"].contains(glyph)
		case .lineBreak, .paragraphBreak: return true
		default: return false
		}
	}
}

/// Runs the deterministic text stages for one dictated utterance in the right order.
public enum DictationTextPipeline {
	public struct Options: Sendable, Equatable {
		public var mode: DictationMode
		public var language: String
		public var englishCommands: Bool
		public var formatNumbers: Bool
		public var agentFormatting: Bool

		public init(mode: DictationMode, language: String = "de", englishCommands: Bool = true, formatNumbers: Bool = true, agentFormatting: Bool = true) {
			self.mode = mode
			self.language = language
			self.englishCommands = englishCommands
			self.formatNumbers = formatNumbers
			self.agentFormatting = agentFormatting
		}
	}

	public static func process(_ text: String, options: Options) -> [TextToken] {
		var tokens = ModelTextTokenizer.tokenize(text)
		if options.mode != .streaming { tokens = SpelledWordRenderer.render(tokens) }
		switch options.mode {
		case .literal:
			tokens = LiteralNormalizer.normalize(tokens)
			if options.formatNumbers { tokens = SpokenNumberFormatter.format(tokens, language: options.language) }
			tokens = InlineCommandRenderer.render(tokens, englishCommands: options.englishCommands)
		case .normal:
			if options.formatNumbers { tokens = SpokenNumberFormatter.format(tokens, language: options.language) }
			if options.agentFormatting { tokens = AgentFormatter.format(tokens) }
		case .streaming:
			if options.formatNumbers { tokens = SpokenNumberFormatter.format(tokens, language: options.language) }
		}
		return tokens
	}

	/// Tokens for a classified utterance, including edge structural commands.
	public static func tokens(for classification: UtteranceClass, options: Options) -> [TextToken] {
		switch classification {
		case let .dictation(leading, text, trailing):
			var tokens: [TextToken] = []
			if let leading { tokens.append(leading == .newLine ? .lineBreak : .paragraphBreak) }
			tokens += process(text, options: options)
			if let trailing { tokens.append(trailing == .newLine ? .lineBreak : .paragraphBreak) }
			return tokens
		case let .command(.structural(command)):
			return [command == .newLine ? .lineBreak : .paragraphBreak]
		case let .command(.format(command)):
			return [.format(command)]
		case .command, .empty:
			return []
		}
	}
}
