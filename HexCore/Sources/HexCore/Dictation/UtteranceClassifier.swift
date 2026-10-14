import Foundation

public enum UtteranceClass: Sendable, Equatable {
	case command(CommandAction)
	/// Dictated text, optionally framed by structural commands spoken at the
	/// utterance edge right next to a measured pause.
	case dictation(leading: StructuralCommand?, text: String, trailing: StructuralCommand?)
	case empty
}

public struct ClassifierContext: Sendable, Equatable {
	public var mode: DictationMode
	public var commandPauseMs: Int
	public var englishCommands: Bool
	public var boxOpen: Bool
	/// Normalized trigger words → snippet text (plan B6).
	public var snippets: [[String]: String]

	public init(mode: DictationMode, commandPauseMs: Int = 450, englishCommands: Bool = true, boxOpen: Bool = false, snippets: [[String]: String] = [:]) {
		self.mode = mode
		self.commandPauseMs = commandPauseMs
		self.englishCommands = englishCommands
		self.boxOpen = boxOpen
		self.snippets = snippets
	}
}

/// Decides whether an utterance is a command or dictation. Commands never fire
/// from silence alone: they need the exact phrase *and* a pause boundary.
public enum UtteranceClassifier {
	public static func classify(
		text: String,
		pauseBeforeMs: Int,
		pauseAfterMs: Int?,
		context: ClassifierContext
	) -> UtteranceClass {
		let words = CommandGrammar.normalizedWords(text)
		guard !words.isEmpty else { return .empty }
		let english = context.englishCommands
		let pauseBefore = pauseBeforeMs >= context.commandPauseMs
		let pauseAfter = (pauseAfterMs ?? Int.max) >= context.commandPauseMs

		if pauseBefore && pauseAfter {
			// A snippet trigger only as an utterance of its own, so „meine Adresse
			// ist neu“ stays text.
			if let snippet = context.snippets[words] {
				return .command(.snippet(snippet))
			}
			if context.boxOpen, let box = CommandGrammar.isolated(words, in: CommandGrammar.box, english: english) {
				return .command(.box(box))
			}
			if let edit = CommandGrammar.editCommand(text, english: english) {
				return .command(.edit(edit))
			}
			if let structural = CommandGrammar.isolated(words, in: CommandGrammar.structural + CommandGrammar.structuralIsolatedOnly, english: english) {
				return .command(.structural(structural))
			}
			if context.mode == .literal,
			   let format = CommandGrammar.isolated(words, in: CommandGrammar.formatIsolated, english: english) {
				return .command(.format(format))
			}
		}

		var leading: StructuralCommand?
		var trailing: StructuralCommand?
		var leadingWordCount = 0
		var trailingWordCount = 0
		if pauseBefore, let match = CommandGrammar.match(words, at: 0, in: CommandGrammar.structural, english: english),
		   match.length < words.count {
			leading = match.0
			leadingWordCount = match.length
		}
		if pauseAfter {
			for length in stride(from: min(3, words.count - leadingWordCount - 1), through: 1, by: -1) where length > 0 {
				let start = words.count - length
				if let match = CommandGrammar.match(words, at: start, in: CommandGrammar.structural, english: english),
				   match.length == length {
					trailing = match.0
					trailingWordCount = length
					break
				}
			}
		}
		let body = dropNormalizedWords(from: text, leading: leadingWordCount, trailing: trailingWordCount)
		return .dictation(leading: leading, text: body, trailing: trailing)
	}

	/// Removes `leading`/`trailing` normalized words from the original text while
	/// keeping its casing and punctuation, and trims punctuation left at the cut.
	static func dropNormalizedWords(from text: String, leading: Int, trailing: Int) -> String {
		guard leading > 0 || trailing > 0 else { return text }
		var pieces = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
		var remaining = leading
		while remaining > 0, !pieces.isEmpty {
			remaining -= max(1, CommandGrammar.normalizedWords(pieces.removeFirst()).count)
		}
		remaining = trailing
		while remaining > 0, !pieces.isEmpty {
			remaining -= max(1, CommandGrammar.normalizedWords(pieces.removeLast()).count)
		}
		var result = pieces.joined(separator: " ")
		let edgePunctuation = CharacterSet(charactersIn: ".,;:!?-–— ")
		if leading > 0 {
			while let first = result.unicodeScalars.first, edgePunctuation.contains(first) { result.removeFirst() }
		}
		if trailing > 0 {
			while let last = result.unicodeScalars.last, CharacterSet(charactersIn: ",;:-–— ").contains(last) { result.removeLast() }
		}
		return result
	}
}
