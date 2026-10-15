import Foundation

/// Literal-mode fine-tuning per engine family (test matrix of 15.10.2026,
/// `dev-docs/04-tests/ergebnisse/2026-10-15_LITERAL_TESTMATRIX.md`).
///
/// Kept apart from the general dictation pipeline: the pipeline only asks the
/// profile whether a rule is on, and a profile is only set for Literal
/// dictation. `.general` holds the engine-independent rules for every batch
/// engine; Whisper and Qwen3-ASR add their own parts. Normal mode, Streaming
/// and file transcription run unchanged.
public struct LiteralTuning: Sendable, Equatable {
	public enum Engine: String, Sendable, Equatable {
		/// Engine-independent rules only (Parakeet, Canary, Cohere, Apple, …).
		case general
		case whisper
		case qwen
	}

	public var engine: Engine
	/// A structural command („Neuer Absatz“, „Neue Zeile“) needs only the pause
	/// before it, also inside an utterance when word timings show that pause.
	public var structuralPauseBeforeOnly = true
	/// Without word timings (Qwen) a structural command inside an utterance
	/// counts at any position.
	public var structuralWithoutTimings = false
	/// „Spiegelstrich“/„Aufzählungspunkt“ starts a list item anywhere, no pause needed.
	public var inlineBullets = true
	/// „… Neuer“ ⏸ „Absatz …“: the split command moves to the utterance after the pause.
	public var joinSplitStructural = true
	/// Only articles, determiners and contracted prepositions make a mark word
	/// a word („einen Punkt“); „Ein Schrägstrich Aus“ is a command, „Punkt 8“ a word.
	public var strictArticleRule = true
	/// „…, nein, ich meine …“ resolves across a period the model inserted.
	public var strongSelfCorrection = true
	/// Removes CJK characters and hallucinated phrases („you“, „Thank you“) at
	/// the start and end of the recording.
	public var cleanup = true
	/// „1250 €“ → „1.250 €“; plain numbers from 10 000 on.
	public var thousandsSeparator = true
	/// „dritten März“ → „3. März“ (dates without a year).
	public var dateNames = true
	/// „2 5 mg“ → „2,5 mg“ when the decoder could not write the comma.
	public var decimalRepair = true
	/// Whisper: decode the speech again that the full-recording pass skipped.
	public var gapFill = false
	/// Pause that splits the recording for per-utterance decoding; nil = command pause.
	public var decodeSegmentPauseMs: Int?

	public init(engine: Engine) {
		self.engine = engine
	}

	/// Every other engine: command, number and cleanup rules, no decoding changes.
	public static let general = LiteralTuning(engine: .general)

	/// Whisper Turbo: full recording + gap fill, all punctuation suppressed in the decoder.
	public static let whisper: LiteralTuning = {
		var tuning = LiteralTuning(engine: .whisper)
		tuning.gapFill = true
		return tuning
	}()

	/// Qwen3-ASR: per-utterance decoding needs longer segments (context), so
	/// commands rely on the word rules instead of pauses.
	public static let qwen: LiteralTuning = {
		var tuning = LiteralTuning(engine: .qwen)
		tuning.structuralWithoutTimings = true
		tuning.decodeSegmentPauseMs = 700
		return tuning
	}()
}

/// Whisper settings of the Literal fine-tuning.
public enum WhisperLiteralTuning {
	/// Tokens made only of these characters are suppressed in Literal mode: the
	/// model writes no punctuation at all, every mark comes from a spoken command.
	public static let suppressedPunctuation = ".,;:!?-–—()[]{}\"'„“”‚‘’«»/\\…%&@_*#+=<>|~^`"
}
