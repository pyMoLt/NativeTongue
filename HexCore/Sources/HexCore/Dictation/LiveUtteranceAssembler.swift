import Foundation

public enum LiveUtteranceAssemblyError: Error, Sendable, Equatable {
	case sampleGap(expected: Int, received: Int)
	case sampleRangeUnavailable(Range<Int>)
}

public enum LiveUtteranceEvent: Sendable, Equatable {
	/// A closed utterance with its bounded 16 kHz mono sample slice, ready for serial ASR.
	case utteranceReady(Utterance, [Float])
	/// Refines the previous utterance's measured pause once the next speech onset is known.
	case pauseAfterKnown(id: Int, milliseconds: Int)
}

/// Incremental VAD plus a bounded sample window. Memory stays bounded by approximately one
/// maximum utterance, while each completed utterance carries its own samples to the scheduler.
public struct LiveUtteranceAssembler: Sendable {
	private var segmenter: UtteranceSegmenter
	private var window: AudioSampleWindow

	public init(config: SegmenterConfig = SegmenterConfig(), sampleWindowSeconds: Int = 28) {
		segmenter = UtteranceSegmenter(config: config)
		window = AudioSampleWindow(capacity: max(config.sampleRate, config.sampleRate * sampleWindowSeconds))
	}

	public mutating func append(_ chunk: AudioChunk) throws -> [LiveUtteranceEvent] {
		try window.append(chunk)
		return try process(segmenter.append(chunk.samples))
	}

	public mutating func finish() throws -> [LiveUtteranceEvent] {
		try process(segmenter.finish())
	}

	private mutating func process(_ events: [SegmenterEvent]) throws -> [LiveUtteranceEvent] {
		try events.map { event in
			switch event {
			case let .utteranceClosed(utterance):
				guard let samples = window.samples(in: utterance.range) else {
					throw LiveUtteranceAssemblyError.sampleRangeUnavailable(utterance.range)
				}
				return .utteranceReady(utterance, samples)
			case let .pauseAfterKnown(id, milliseconds):
				return .pauseAfterKnown(id: id, milliseconds: milliseconds)
			}
		}
	}
}

private struct AudioSampleWindow: Sendable {
	let capacity: Int
	private var samples: [Float] = []
	private var startSample = 0
	private var endSample = 0

	init(capacity: Int) {
		self.capacity = max(1, capacity)
		samples.reserveCapacity(max(1, capacity))
	}

	mutating func append(_ chunk: AudioChunk) throws {
		guard chunk.startSample == endSample else {
			throw LiveUtteranceAssemblyError.sampleGap(expected: endSample, received: chunk.startSample)
		}
		samples.append(contentsOf: chunk.samples)
		endSample += chunk.samples.count

		let overflow = samples.count - capacity
		if overflow > 0 {
			samples.removeFirst(overflow)
			startSample += overflow
		}
	}

	func samples(in range: Range<Int>) -> [Float]? {
		guard range.lowerBound >= startSample,
		      range.upperBound <= endSample,
		      range.lowerBound <= range.upperBound
		else { return nil }
		let lower = range.lowerBound - startSample
		let upper = range.upperBound - startSample
		return Array(samples[lower..<upper])
	}
}
