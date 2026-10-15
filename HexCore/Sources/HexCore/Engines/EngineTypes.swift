import Foundation

/// How an engine can keep automatic punctuation out of literal dictation.
public enum PunctuationControl: String, Codable, Sendable, Equatable {
	/// Punctuation tokens are masked in the decoder (Whisper `supressTokens`, Qwen logit mask).
	case decoderSuppression
	/// The model has a prompt/flag for "no punctuation" (Canary `<|nopnc|>`, Apple presets).
	case promptFlag
	/// Only deterministic removal after decoding is possible.
	case stripOnly
	case none
}

public enum BiasingKind: String, Codable, Sendable, Equatable {
	case contextText        // Qwen3-ASR context string
	case promptTokens       // Whisper prompt tokens (experimental; can drop text)
	case ctcBoost           // FluidAudio CTC keyword boosting for Parakeet
	case contextualStrings  // Apple SpeechAnalyzer AnalysisContext
}

public struct EngineCapabilities: Codable, Sendable, Equatable {
	public var languages: [String]
	public var supportsAutoLanguage: Bool
	public var wordTimings: Bool
	public var tokenConfidences: Bool
	public var punctuationControl: PunctuationControl
	public var biasing: [BiasingKind]
	public var maxWindowSeconds: Double?
	public var diarization: Bool

	public init(
		languages: [String],
		supportsAutoLanguage: Bool,
		wordTimings: Bool,
		tokenConfidences: Bool,
		punctuationControl: PunctuationControl,
		biasing: [BiasingKind] = [],
		maxWindowSeconds: Double? = nil,
		diarization: Bool = false
	) {
		self.languages = languages
		self.supportsAutoLanguage = supportsAutoLanguage
		self.wordTimings = wordTimings
		self.tokenConfidences = tokenConfidences
		self.punctuationControl = punctuationControl
		self.biasing = biasing
		self.maxWindowSeconds = maxWindowSeconds
		self.diarization = diarization
	}
}

public enum PunctuationPolicy: String, Sendable, Equatable {
	case natural
	case suppressed
}

public struct RequestOptions: Sendable, Equatable {
	/// `nil` means automatic language detection.
	public var language: String?
	public var punctuation: PunctuationPolicy
	/// Only filled when the user enabled the model-specific biasing option.
	public var biasTerms: [String]
	/// File transcription: waits behind dictation for the model.
	public var isBackground: Bool
	/// Literal fine-tuning is active (`LiteralTuning`): Whisper suppresses every punctuation token.
	public var literalTuning = false

	public init(language: String?, punctuation: PunctuationPolicy, biasTerms: [String] = [], isBackground: Bool = false) {
		self.language = language
		self.punctuation = punctuation
		self.biasTerms = biasTerms
		self.isBackground = isBackground
	}
}

public struct EngineWord: Sendable, Equatable {
	public let text: String
	public let start: Double
	public let end: Double
	public let confidence: Float?

	public init(text: String, start: Double, end: Double, confidence: Float? = nil) {
		self.text = text
		self.start = start
		self.end = end
		self.confidence = confidence
	}
}

public struct EngineResult: Sendable, Equatable {
	public var text: String
	public var words: [EngineWord]
	public var detectedLanguage: String?
	public var punctuationWasSuppressed: Bool

	public init(text: String, words: [EngineWord] = [], detectedLanguage: String? = nil, punctuationWasSuppressed: Bool = false) {
		self.text = text
		self.words = words
		self.detectedLanguage = detectedLanguage
		self.punctuationWasSuppressed = punctuationWasSuppressed
	}
}

/// Detects when context/prompt biasing leaked the bias list itself into the transcript
/// (observed with Qwen3-ASR: the whole context list was copied into the text).
public enum BiasLeakGuard {
	/// Returns the range of a leaked run: at least `minimumRun` bias terms appearing
	/// consecutively in list order, separated only by commas/whitespace.
	public static func leakedRange(in text: String, biasTerms: [String], minimumRun: Int = 3) -> Range<String.Index>? {
		guard minimumRun > 0, biasTerms.count >= minimumRun else { return nil }
		let separator = "[\\s,;]+"
		func pattern(_ terms: ArraySlice<String>) -> String {
			terms.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: separator) + "[\\s,;.]*"
		}
		for start in 0...(biasTerms.count - minimumRun) {
			var end = start + minimumRun
			guard var best = text.range(of: pattern(biasTerms[start..<end]), options: [.regularExpression, .caseInsensitive]) else {
				continue
			}
			while end < biasTerms.count,
			      let longer = text.range(of: pattern(biasTerms[start..<(end + 1)]), options: [.regularExpression, .caseInsensitive]) {
				best = longer
				end += 1
			}
			return best
		}
		return nil
	}
}
