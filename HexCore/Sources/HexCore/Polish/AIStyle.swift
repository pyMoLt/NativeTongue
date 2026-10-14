import Foundation

/// One way the local language model may process a text (2.6 "AI styles").
/// The same list is used everywhere: automatic step, dictation box ✨, files,
/// Command Mode and profiles. Built-in styles can be edited and restored;
/// users can add their own.
public struct AIStyle: Codable, Equatable, Identifiable, Sendable {
	public var id: String
	public var name: String
	public var symbol: String
	/// System instruction for the model.
	public var instruction: String
	/// Optional worked example (few-shot); helps small models a lot.
	public var exampleInput: String
	public var exampleOutput: String
	/// How strictly the result is compared with the original.
	public var strictness: GuardStrictness
	/// Allowed change in length (percent) for the length check.
	public var lengthTolerancePercent: Int
	/// Output budget relative to the input length.
	public var outputFactor: Double
	/// Long texts are processed paragraph by paragraph (content-preserving styles).
	public var chunked: Bool

	public init(
		id: String,
		name: String,
		symbol: String = "sparkles",
		instruction: String,
		exampleInput: String = "",
		exampleOutput: String = "",
		strictness: GuardStrictness = .keyFacts,
		lengthTolerancePercent: Int = 25,
		outputFactor: Double = 1.3,
		chunked: Bool = false
	) {
		self.id = id
		self.name = name
		self.symbol = symbol
		self.instruction = instruction
		self.exampleInput = exampleInput
		self.exampleOutput = exampleOutput
		self.strictness = strictness
		self.lengthTolerancePercent = lengthTolerancePercent
		self.outputFactor = outputFactor
		self.chunked = chunked
	}

	public var isBuiltIn: Bool { AIStyleCatalog.builtIn(id: id) != nil }
	public var isCustom: Bool { !isBuiltIn }

	/// A new, empty user style.
	public static func newCustom(name: String = "My style") -> AIStyle {
		AIStyle(
			id: "custom-\(UUID().uuidString.prefix(8).lowercased())",
			name: name,
			symbol: "wand.and.stars",
			instruction: "Rewrite the dictated text as …. Keep every fact, number, name and negation. Keep the language of the input.",
			strictness: .keyFacts,
			outputFactor: 1.5
		)
	}

	/// A one-off style for an instruction typed by the user (files, Command Mode).
	public static func oneOff(instruction: String) -> AIStyle {
		AIStyle(
			id: "one-off",
			name: "Own instruction",
			symbol: "pencil.and.list.clipboard",
			instruction: """
			You process a transcript of spoken language. Follow the user's instruction below and reply with the result only. Keep numbers, names and negations exactly. Do not invent anything that was not said.

			Instruction: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))
			""",
			strictness: .off,
			outputFactor: 1.5
		)
	}

	private enum CodingKeys: String, CodingKey {
		case id, name, symbol, instruction, exampleInput, exampleOutput, strictness, lengthTolerancePercent, outputFactor, chunked
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		let base = AIStyleCatalog.builtIn(id: id)
		name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? base?.name ?? "Style"
		symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? base?.symbol ?? "sparkles"
		instruction = (try? c.decodeIfPresent(String.self, forKey: .instruction)) ?? base?.instruction ?? ""
		exampleInput = (try? c.decodeIfPresent(String.self, forKey: .exampleInput)) ?? base?.exampleInput ?? ""
		exampleOutput = (try? c.decodeIfPresent(String.self, forKey: .exampleOutput)) ?? base?.exampleOutput ?? ""
		strictness = (try? c.decodeIfPresent(GuardStrictness.self, forKey: .strictness)) ?? base?.strictness ?? .keyFacts
		lengthTolerancePercent = (try? c.decodeIfPresent(Int.self, forKey: .lengthTolerancePercent)) ?? base?.lengthTolerancePercent ?? 25
		outputFactor = (try? c.decodeIfPresent(Double.self, forKey: .outputFactor)) ?? base?.outputFactor ?? 1.3
		chunked = (try? c.decodeIfPresent(Bool.self, forKey: .chunked)) ?? base?.chunked ?? false
	}
}

/// The built-in styles.
public enum AIStyleCatalog {
	public static let cleanID = "clean"
	public static let cleanSentencesID = "clean-sentences"
	public static let taskID = "task"
	public static let keyFactsID = "key-facts"
	public static let emailID = "email"
	public static let messageID = "message"
	public static let noteID = "note"
	public static let promptID = "prompt"

	public static let builtIns: [AIStyle] = [
		AIStyle(id: cleanID, name: "Clean up", symbol: "textformat.abc",
		        instruction: PolishPrompt.defaultClean, strictness: .strict, lengthTolerancePercent: 40, outputFactor: 1.5, chunked: true),
		AIStyle(id: cleanSentencesID, name: "Clean sentences", symbol: "text.alignleft",
		        instruction: cleanSentencesPrompt,
		        exampleInput: "ja also ähm wir waren gestern beim kunden und der kunde der hat gesagt dass er nein dass sie das angebot bis montag braucht",
		        exampleOutput: "Wir waren gestern beim Kunden. Die Kundin hat gesagt, dass sie das Angebot bis Montag braucht.",
		        strictness: .keyFacts, lengthTolerancePercent: 40, outputFactor: 1.3, chunked: true),
		AIStyle(id: taskID, name: "Rewrite as task", symbol: "checklist",
		        instruction: PolishPrompt.defaultRewrite, strictness: .keyFacts, outputFactor: 1.2),
		AIStyle(id: keyFactsID, name: "Key facts", symbol: "list.bullet.rectangle",
		        instruction: keyFactsPrompt, strictness: .off, outputFactor: 0.6),
		AIStyle(id: emailID, name: "E-mail", symbol: "envelope",
		        instruction: emailPrompt, exampleInput: emailExampleInput, exampleOutput: emailExampleOutput,
		        strictness: .keyFacts, outputFactor: 1.6),
		AIStyle(id: messageID, name: "Short message", symbol: "bubble.left",
		        instruction: messagePrompt, strictness: .keyFacts, outputFactor: 1.0),
		AIStyle(id: noteID, name: "Note", symbol: "note.text",
		        instruction: notePrompt, strictness: .keyFacts, outputFactor: 1.3),
		AIStyle(id: promptID, name: "Prompt", symbol: "bubble.left.and.text.bubble.right",
		        instruction: promptPrompt, exampleInput: promptExampleInput, exampleOutput: promptExampleOutput,
		        strictness: .keyFacts, outputFactor: 1.4),
	]

	/// "Clean up" as shipped.
	public static var clean: AIStyle { builtIns[0] }
	/// "Rewrite as task" as shipped.
	public static var task: AIStyle { builtIns[2] }

	public static func builtIn(id: String) -> AIStyle? {
		builtIns.first { $0.id == id }
	}

	public static let cleanSentencesPrompt = """
	You turn a transcript of spoken language into clean written text. Reply with the rewritten text only, in the same language as the transcript: German stays German, English stays English. Never translate.

	- Write complete, well-formed sentences and sensible paragraphs.
	- Remove filler words, false starts, repetitions and self-corrections (keep the corrected version).
	- Keep every statement, its order and its meaning. Do not summarise, shorten content, add facts or answer questions.
	- Keep numbers, doses, units, dates, names, negations and technical terms exactly.
	- Keep speaker labels ("Speaker 1:" or names) when present.
	- Keep the language of the input.
	"""

	public static let keyFactsPrompt = """
	You extract the key facts from a transcript. Reply with a Markdown list only (each line starts with "- "), most important first, in the language of the transcript.

	- One fact per line, short and precise: decisions, results, tasks, dates, numbers, names.
	- Keep numbers, doses, units, dates, names and negations exactly as said.
	- Only what was said: do not interpret, judge, add or answer anything.
	- Write in the language of the transcript.
	"""

	public static let emailPrompt = """
	You turn dictated content into a clear, friendly e-mail body. Reply with the e-mail text only (no subject line, no explanations), in the language of the input. Never translate.

	The dictation is written by the sender. Keep the sender's perspective exactly: what the sender does, needs or asks for stays the sender's ("ich brauche noch die Zahlen" → "Ich brauche noch die Zahlen …" or "Könnten Sie mir noch die Zahlen schicken?"), never a question to the recipient about their needs.
	Write a question only where the dictation itself asks one ("können wir …", "kommst du …"); every other sentence stays a statement.

	- Start with a fitting greeting and end with a short closing, in the language of the input; use names only if they were dictated.
	- Keep every fact, request, date, number, name and negation. Do not add promises, facts or details that were not said.
	- Keep who does or needs what: a statement stays a statement ("ich brauche noch …" stays "ich brauche noch …"), a question stays a question.
	- Short paragraphs; a list only when several items were dictated.
	- Keep the language of the input and its level of formality (du/Sie).
	"""

	public static let emailExampleInput = "hallo frau meier der termin am donnerstag um zehn klappt bei mir nicht können wir auf freitag gehen ich brauche noch ihre unterlagen vom september danke"
	public static let emailExampleOutput = """
	Hallo Frau Meier,

	der Termin am Donnerstag um 10 Uhr klappt bei mir leider nicht. Können wir ihn auf Freitag verschieben?

	Außerdem brauche ich noch Ihre Unterlagen vom September.

	Vielen Dank und viele Grüße
	"""

	public static let messagePrompt = """
	You turn dictated content into a short chat message. Reply with the message only, in the language of the input. Never translate.

	- Concise and natural, like a person writes in a messenger; one to three sentences.
	- Keep every fact, request, time, number, name and negation. Add nothing.
	- No greeting or sign-off unless it was dictated. Keep the language of the input.
	"""

	public static let promptPrompt = """
	You turn dictated thoughts into a clear prompt for an AI assistant. Reply with the prompt only, in the language of the input. Never translate.

	- Keep the speaker's intent and every requirement, constraint, example, name, number, file name, command and piece of code exactly.
	- Remove filler words, false starts and repetitions; resolve self-corrections to the final intent.
	- Order the content: goal first, then details or constraints; use a short list when there are several points.
	- Do not answer the prompt, do not add requirements and do not address the assistant with greetings.
	"""

	public static let promptExampleInput = "ähm also schreib mir bitte eine funktion in swift die eine liste von zahlen sortiert nein warte absteigend sortiert und keine externen bibliotheken"
	public static let promptExampleOutput = """
	Schreibe eine Swift-Funktion, die eine Liste von Zahlen absteigend sortiert.

	- Keine externen Bibliotheken verwenden.
	"""

	public static let notePrompt = """
	You turn dictated content into a tidy note. Reply with the note only, in Markdown, in the language of the input. Never translate.

	- A short title line (# …) only when the topic is clear, then a list where each line starts with "- ", or short paragraphs.
	- Spell words exactly as dictated; do not shorten or alter names and compound words.
	- Keep every fact, number, date, name and negation; keep the order of topics.
	- Do not add, interpret or answer anything. Keep the language of the input.
	"""
}
