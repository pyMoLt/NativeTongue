import Foundation

/// An ASR text span associated with a pause-delimited audio utterance.
public struct AlignedUtterance: Sendable, Equatable {
	public let utterance: Utterance
	public let text: String
	public let language: String?

	public init(utterance: Utterance, text: String, language: String? = nil) {
		self.utterance = utterance
		self.text = text
		self.language = language
	}
}

/// How an app session should acquire text while preserving enough ASR context.
public enum SessionTranscriptionStrategy: Sendable, Equatable {
	/// Decode one complete recording, then use word timestamps to assign text to
	/// the audio-derived utterances. This avoids losing short command phrases at
	/// isolated clip boundaries.
	case fullRecordingThenAlign
	/// If the engine cannot return usable timings, decode each VAD utterance in
	/// sequence so command decisions still use measured audio pauses.
	case transcribeUtterancesSequentially
}

public struct DictationSessionOptions: Sendable, Equatable {
	public var mode: DictationMode
	public var commandPauseMs: Int
	public var englishCommands: Bool
	public var language: String
	public var formatNumbers: Bool
	public var agentFormatting: Bool
	public var boxOpen: Bool

	public init(
		mode: DictationMode,
		commandPauseMs: Int = 450,
		englishCommands: Bool = true,
		language: String = "de",
		formatNumbers: Bool = true,
		agentFormatting: Bool = true,
		boxOpen: Bool = false
	) {
		self.mode = mode
		self.commandPauseMs = commandPauseMs
		self.englishCommands = englishCommands
		self.language = language
		self.formatNumbers = formatNumbers
		self.agentFormatting = agentFormatting
		self.boxOpen = boxOpen
	}
}

/// Maps a full-recording transcript onto audio VAD segments and applies the
/// deterministic command/document pipeline. No ASR or UI dependencies live here.
public enum DictationSessionProcessor {
	/// Choose full-recording decoding whenever word timings are supported. If the
	/// engine fails to produce usable timings at runtime, callers must fall back
	/// to the sequential utterance strategy.
	public static func preferredStrategy(for capabilities: EngineCapabilities) -> SessionTranscriptionStrategy {
		capabilities.wordTimings ? .fullRecordingThenAlign : .transcribeUtterancesSequentially
	}

	/// Align word-level ASR output to VAD utterances using the word midpoint. A
	/// small outside-range tolerance accommodates backends that stretch a word's
	/// timestamp over trailing silence (observed in Parakeet/TDT). Returns `nil`
	/// when timing coverage is too poor, signalling the caller to transcribe the
	/// utterances individually rather than silently dropping transcript text.
	public static func align(
		_ result: EngineResult,
		to utterances: [Utterance],
		sampleRate: Int = 16_000,
		maximumDistanceSeconds: Double = 0.9,
		minimumWordCoverage: Double = 0.75
	) -> [AlignedUtterance]? {
		guard sampleRate > 0, !utterances.isEmpty, !result.words.isEmpty else { return nil }
		let validWords = result.words.filter {
			$0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !$0.text.isEmpty
		}
		guard !validWords.isEmpty else { return nil }

		var grouped = Array(repeating: [String](), count: utterances.count)
		var assignedCount = 0
		for word in validWords {
			let midpoint = (word.start + word.end) / 2
			let best = utterances.indices.min { lhs, rhs in
				let leftDistance = distance(midpoint, to: utterances[lhs].range, sampleRate: sampleRate)
				let rightDistance = distance(midpoint, to: utterances[rhs].range, sampleRate: sampleRate)
				if leftDistance == rightDistance {
					return centerDistance(midpoint, to: utterances[lhs].range, sampleRate: sampleRate)
						< centerDistance(midpoint, to: utterances[rhs].range, sampleRate: sampleRate)
				}
				return leftDistance < rightDistance
			}
			guard let best,
			      distance(midpoint, to: utterances[best].range, sampleRate: sampleRate) <= maximumDistanceSeconds
			else { continue }
			grouped[best].append(word.text)
			assignedCount += 1
		}

		guard Double(assignedCount) / Double(validWords.count) >= minimumWordCoverage else { return nil }
		return zip(utterances, grouped).map { utterance, words in
			AlignedUtterance(
				utterance: utterance,
				text: words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
				language: result.detectedLanguage
			)
		}
	}

	public static func makeDocument(
		from alignedUtterances: [AlignedUtterance],
		options: DictationSessionOptions
	) -> DictationDocument {
		var document = DictationDocument()
		let classifierContext = ClassifierContext(
			mode: options.mode,
			commandPauseMs: options.commandPauseMs,
			englishCommands: options.englishCommands,
			boxOpen: options.boxOpen
		)
		for item in alignedUtterances {
			let classification = UtteranceClassifier.classify(
				text: item.text,
				pauseBeforeMs: item.utterance.pauseBeforeMs,
				pauseAfterMs: item.utterance.pauseAfterMs,
				context: classifierContext
			)
			if case let .command(.edit(command)) = classification {
				document.apply(command)
				continue
			}
			let pipelineOptions = DictationTextPipeline.Options(
				mode: options.mode,
				language: item.language ?? options.language,
				englishCommands: options.englishCommands,
				formatNumbers: options.formatNumbers,
				agentFormatting: options.agentFormatting
			)
			let tokens = DictationTextPipeline.tokens(for: classification, options: pipelineOptions)
			document.append(utteranceID: item.utterance.id, tokens: tokens)
		}
		return document
	}

	private static func distance(_ seconds: Double, to range: Range<Int>, sampleRate: Int) -> Double {
		let lower = Double(range.lowerBound) / Double(sampleRate)
		let upper = Double(range.upperBound) / Double(sampleRate)
		if seconds < lower { return lower - seconds }
		if seconds > upper { return seconds - upper }
		return 0
	}

	private static func centerDistance(_ seconds: Double, to range: Range<Int>, sampleRate: Int) -> Double {
		let center = Double(range.lowerBound + range.upperBound) / (2 * Double(sampleRate))
		return abs(seconds - center)
	}
}
