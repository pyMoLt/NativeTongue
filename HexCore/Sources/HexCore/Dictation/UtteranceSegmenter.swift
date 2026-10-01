import Foundation

public struct SegmenterConfig: Sendable, Equatable {
	public var sampleRate: Int = 16_000
	public var frameMs: Int = 20
	/// Minimum silence that ends an utterance. Equals the user's command-pause setting.
	public var minPauseMs: Int = 450
	/// Speech shorter than this is treated as a click/blip and dropped.
	public var minSpeechMs: Int = 200
	public var preRollMs: Int = 150
	public var postRollMs: Int = 150
	/// Longer utterances are split at the quietest frame of their last 5 s (Whisper window is 30 s).
	public var maxUtteranceMs: Int = 25_000
	public var noiseWindowMs: Int = 3_000
	public var speechWindowMs: Int = 10_000
	public var thresholdRatio: Float = 0.35
	public var minDynamicDb: Float = 6
	/// Fixed threshold used until one second of audio is available.
	public var warmupThresholdDb: Float = -45
	public var onsetFrames: Int = 2

	public init() {}

	public init(minPauseMs: Int) {
		self.minPauseMs = minPauseMs
	}

	var samplesPerFrame: Int { sampleRate * frameMs / 1_000 }
}

public enum SegmenterEvent: Sendable, Equatable {
	/// An utterance ended. `pauseAfterMs` is a lower bound (≥ `minPauseMs`) until refined.
	case utteranceClosed(Utterance)
	/// The exact silence after a previously closed utterance became known.
	case pauseAfterKnown(id: Int, ms: Int)
}

/// Splits a 16 kHz mono stream into pause-delimited utterances using an adaptive
/// energy threshold (rolling noise floor + fraction of the speech dynamic range).
public struct UtteranceSegmenter: Sendable {
	public let config: SegmenterConfig

	private var pending: [Float] = []
	private var frameDb: [Float] = []
	private var totalSamples = 0

	private var inSpeech = false
	private var aboveRun = 0
	private var speechStartFrame = 0
	private var lastSpeechFrame = 0
	private var silenceRun = 0

	private var nextID = 0
	private var lastClosed: (id: Int, lastSpeechFrame: Int)?
	private var nextPauseBeforeOverride: Int?
	private var cachedThreshold: Float?

	public init(config: SegmenterConfig = SegmenterConfig()) {
		self.config = config
	}

	public mutating func append<S: Collection>(_ samples: S) -> [SegmenterEvent] where S.Element == Float {
		pending.append(contentsOf: samples)
		totalSamples += samples.count
		var events: [SegmenterEvent] = []
		let n = config.samplesPerFrame
		var offset = 0
		while pending.count - offset >= n {
			let db = Self.decibels(pending[offset..<(offset + n)])
			offset += n
			frameDb.append(db)
			events += process(frame: frameDb.count - 1, db: db)
		}
		pending.removeFirst(offset)
		return events
	}

	public mutating func finish() -> [SegmenterEvent] {
		var events: [SegmenterEvent] = []
		if inSpeech {
			events += close(atLastSpeechFrame: lastSpeechFrame, pauseAfterMs: Int.max)
			inSpeech = false
		}
		if let lastClosed, !events.contains(where: {
			if case let .utteranceClosed(u) = $0 { return u.id == lastClosed.id }
			return false
		}) {
			let silenceMs = max(0, frameDb.count - 1 - lastClosed.lastSpeechFrame) * config.frameMs
			events.append(.pauseAfterKnown(id: lastClosed.id, ms: max(silenceMs, config.minPauseMs)))
		}
		return events
	}

	/// Convenience for files: segments a complete buffer.
	public static func segment(_ samples: [Float], config: SegmenterConfig = SegmenterConfig()) -> [Utterance] {
		var segmenter = UtteranceSegmenter(config: config)
		var utterances: [Utterance] = []
		func apply(_ events: [SegmenterEvent]) {
			for event in events {
				switch event {
				case let .utteranceClosed(u): utterances.append(u)
				case let .pauseAfterKnown(id, ms):
					if let i = utterances.firstIndex(where: { $0.id == id }) { utterances[i].pauseAfterMs = ms }
				}
			}
		}
		apply(segmenter.append(samples))
		apply(segmenter.finish())
		return utterances
	}

	// MARK: - Internals

	private mutating func process(frame f: Int, db: Float) -> [SegmenterEvent] {
		if cachedThreshold == nil || f % 5 == 0 { cachedThreshold = currentThreshold() }
		let threshold = cachedThreshold ?? config.warmupThresholdDb
		let isSpeech = db >= threshold
		var events: [SegmenterEvent] = []

		if !inSpeech {
			aboveRun = isSpeech ? aboveRun + 1 : 0
			if aboveRun >= config.onsetFrames {
				inSpeech = true
				speechStartFrame = f - config.onsetFrames + 1
				lastSpeechFrame = f
				silenceRun = 0
				aboveRun = 0
				if let lastClosed {
					let gap = max(0, speechStartFrame - lastClosed.lastSpeechFrame - 1) * config.frameMs
					events.append(.pauseAfterKnown(id: lastClosed.id, ms: gap))
				}
			}
			return events
		}

		if isSpeech {
			lastSpeechFrame = f
			silenceRun = 0
		} else {
			silenceRun += 1
		}

		if silenceRun * config.frameMs >= config.minPauseMs {
			events += close(atLastSpeechFrame: lastSpeechFrame, pauseAfterMs: silenceRun * config.frameMs)
			inSpeech = false
			silenceRun = 0
			return events
		}

		let lengthMs = (f - speechStartFrame + 1) * config.frameMs
		if lengthMs >= config.maxUtteranceMs {
			let lookback = max(speechStartFrame + 1, f - 5_000 / config.frameMs)
			var splitFrame = f
			var minDb = Float.greatestFiniteMagnitude
			for candidate in lookback...f where frameDb[candidate] < minDb {
				minDb = frameDb[candidate]
				splitFrame = candidate
			}
			events += close(atLastSpeechFrame: max(speechStartFrame, splitFrame - 1), pauseAfterMs: 0)
			// Continue the same speech run as a new utterance without a pause boundary.
			inSpeech = true
			speechStartFrame = min(splitFrame + 1, f)
			lastSpeechFrame = f
			nextPauseBeforeOverride = 0
		}
		return events
	}

	private mutating func close(atLastSpeechFrame last: Int, pauseAfterMs: Int) -> [SegmenterEvent] {
		let speechMs = (last - speechStartFrame + 1) * config.frameMs
		guard speechMs >= config.minSpeechMs else {
			nextPauseBeforeOverride = nil
			return []
		}
		let n = config.samplesPerFrame
		let pre = config.preRollMs * config.sampleRate / 1_000
		let post = config.postRollMs * config.sampleRate / 1_000
		let start = max(0, speechStartFrame * n - pre)
		let end = min(totalSamples, (last + 1) * n + post)
		let pauseBefore: Int
		if let override = nextPauseBeforeOverride {
			pauseBefore = override
		} else if let lastClosed {
			pauseBefore = max(0, speechStartFrame - lastClosed.lastSpeechFrame - 1) * config.frameMs
		} else {
			pauseBefore = Int.max
		}
		nextPauseBeforeOverride = nil
		let utterance = Utterance(id: nextID, range: start..<max(start, end), pauseBeforeMs: pauseBefore, pauseAfterMs: pauseAfterMs)
		lastClosed = (nextID, last)
		nextID += 1
		return [.utteranceClosed(utterance)]
	}

	private func currentThreshold() -> Float {
		let framesPerSecond = 1_000 / config.frameMs
		guard frameDb.count >= framesPerSecond else { return config.warmupThresholdDb }
		let noiseFrames = config.noiseWindowMs / config.frameMs
		let speechFrames = config.speechWindowMs / config.frameMs
		let floor = Self.percentile(frameDb.suffix(noiseFrames), 0.10)
		let speech = Self.percentile(frameDb.suffix(speechFrames), 0.90)
		return floor + max(config.minDynamicDb, config.thresholdRatio * (speech - floor))
	}

	static func decibels<C: Collection>(_ samples: C) -> Float where C.Element == Float {
		var sum: Float = 0
		for s in samples { sum += s * s }
		let rms = (sum / Float(max(samples.count, 1))).squareRoot()
		return 20 * log10(rms + 1e-9)
	}

	static func percentile<C: Collection>(_ values: C, _ p: Float) -> Float where C.Element == Float {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return -120 }
		let index = min(sorted.count - 1, max(0, Int((Float(sorted.count - 1) * p).rounded())))
		return sorted[index]
	}
}
