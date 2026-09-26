import Foundation

/// A block of 16 kHz mono Float32 samples delivered by the live capture tap.
public struct AudioChunk: Sendable, Equatable {
	public let samples: [Float]
	/// Index of the first sample relative to the start of the recording.
	public let startSample: Int

	public init(samples: [Float], startSample: Int) {
		self.samples = samples
		self.startSample = startSample
	}
}

/// A pause-delimited stretch of speech inside one recording.
///
/// Pauses are measured on the audio signal itself. ASR word timings are never
/// used for this, because transducer models (Parakeet/TDT) attribute trailing
/// silence to the preceding word and report near-zero gaps.
public struct Utterance: Sendable, Equatable, Identifiable {
	public let id: Int
	/// Sample range including pre-/post-roll padding.
	public let range: Range<Int>
	/// Measured silence before the first speech frame. `Int.max` at the start of a recording.
	public let pauseBeforeMs: Int
	/// Measured silence after the last speech frame. `nil` until known; `Int.max` at the end of a recording.
	public var pauseAfterMs: Int?

	public init(id: Int, range: Range<Int>, pauseBeforeMs: Int, pauseAfterMs: Int? = nil) {
		self.id = id
		self.range = range
		self.pauseBeforeMs = pauseBeforeMs
		self.pauseAfterMs = pauseAfterMs
	}

	public func durationMs(sampleRate: Int = 16_000) -> Int {
		range.count * 1_000 / sampleRate
	}
}
