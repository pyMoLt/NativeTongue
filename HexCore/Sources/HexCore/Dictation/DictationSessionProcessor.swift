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
	public var sampleRate: Int

	public init(
		mode: DictationMode,
		commandPauseMs: Int = 450,
		englishCommands: Bool = true,
		language: String = "de",
		formatNumbers: Bool = true,
		agentFormatting: Bool = true,
		boxOpen: Bool = false,
		sampleRate: Int = 16_000
	) {
		self.mode = mode
		self.commandPauseMs = commandPauseMs
		self.englishCommands = englishCommands
		self.language = language
		self.formatNumbers = formatNumbers
		self.agentFormatting = agentFormatting
		self.boxOpen = boxOpen
		self.sampleRate = sampleRate
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

	/// Align word-level ASR output to VAD utterances using the word midpoint.
	/// No word is ever dropped: a word outside every utterance (e.g. a TDT
	/// timestamp stretched over trailing silence, or quiet speech below the VAD
	/// threshold) goes to the nearest utterance, and a word without usable timing
	/// follows its predecessor. Returns `nil` only when fewer than half of the
	/// words carry usable timings; callers then decode utterance by utterance.
	public static func align(
		_ result: EngineResult,
		to utterances: [Utterance],
		sampleRate: Int = 16_000,
		minimumTimedFraction: Double = 0.5
	) -> [AlignedUtterance]? {
		guard sampleRate > 0, !utterances.isEmpty, !result.words.isEmpty else { return nil }
		let words = result.words.filter { !$0.text.isEmpty }
		func isTimed(_ word: EngineWord) -> Bool {
			word.start.isFinite && word.end.isFinite && word.start >= 0 && word.end >= word.start
		}
		let timedCount = words.filter(isTimed).count
		guard !words.isEmpty, Double(timedCount) / Double(words.count) >= minimumTimedFraction else { return nil }

		var grouped = Array(repeating: [String](), count: utterances.count)
		var current = 0
		for word in words {
			if isTimed(word) {
				let midpoint = (word.start + word.end) / 2
				current = nearestUtterance(to: midpoint, in: utterances, sampleRate: sampleRate, notBefore: current)
			}
			grouped[current].append(word.text)
		}
		return zip(utterances, grouped).map { utterance, words in
			AlignedUtterance(
				utterance: utterance,
				text: words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
				language: result.detectedLanguage
			)
		}
	}

	/// Words arrive in spoken order, so the search never goes back before the
	/// previous word's utterance (keeps text order stable with jittery timings).
	private static func nearestUtterance(to seconds: Double, in utterances: [Utterance], sampleRate: Int, notBefore: Int) -> Int {
		var best = notBefore
		var bestDistance = Double.infinity
		for index in notBefore ..< utterances.count {
			let value = distance(seconds, to: utterances[index].range, sampleRate: sampleRate)
			let center = centerDistance(seconds, to: utterances[index].range, sampleRate: sampleRate)
			let bestCenter = centerDistance(seconds, to: utterances[best].range, sampleRate: sampleRate)
			if value < bestDistance || (value == bestDistance && center < bestCenter) {
				best = index
				bestDistance = value
			}
		}
		return best
	}

	public static func makeDocument(
		from alignedUtterances: [AlignedUtterance],
		options: DictationSessionOptions,
		corrector: LexiconCorrector? = nil
	) -> DictationDocument {
		var document = DictationDocument()
		let classifierContext = ClassifierContext(
			mode: options.mode,
			commandPauseMs: options.commandPauseMs,
			englishCommands: options.englishCommands,
			boxOpen: options.boxOpen
		)
		for item in alignedUtterances {
			let durationMs = item.utterance.range.count * 1_000 / max(options.sampleRate, 1)
			if HallucinationFilter.shouldDrop(text: item.text, utteranceDurationMs: durationMs) { continue }
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
			if case let .command(.box(command)) = classification {
				document.record(command)
				continue
			}
			let pipelineOptions = DictationTextPipeline.Options(
				mode: options.mode,
				language: item.language ?? options.language,
				englishCommands: options.englishCommands,
				formatNumbers: options.formatNumbers,
				agentFormatting: options.agentFormatting
			)
			var tokens = DictationTextPipeline.tokens(for: classification, options: pipelineOptions)
			var corrections: [LexiconCorrection] = []
			if let corrector, case .dictation = classification {
				(tokens, corrections) = corrector.correct(tokens)
			}
			document.append(utteranceID: item.utterance.id, tokens: tokens, corrections: corrections)
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
