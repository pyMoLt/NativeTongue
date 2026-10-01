import Foundation

/// Groups resampled live audio into bounded, position-aware chunks for streaming consumers.
public struct AudioChunker: Sendable {
	public let chunkSize: Int

	private var pending: [Float] = []
	private var nextSample = 0

	public init(chunkSize: Int = 2_048) {
		self.chunkSize = max(1, chunkSize)
		pending.reserveCapacity(max(1, chunkSize))
	}

	public mutating func append<S: Collection>(_ samples: S) -> [AudioChunk] where S.Element == Float {
		pending.append(contentsOf: samples)
		var chunks: [AudioChunk] = []
		while pending.count >= chunkSize {
			chunks.append(AudioChunk(samples: Array(pending[..<chunkSize]), startSample: nextSample))
			pending.removeFirst(chunkSize)
			nextSample += chunkSize
		}
		return chunks
	}

	/// Emits the final short chunk at the end of a recording, if any.
	public mutating func finish() -> [AudioChunk] {
		guard !pending.isEmpty else { return [] }
		let chunk = AudioChunk(samples: pending, startSample: nextSample)
		nextSample += pending.count
		pending.removeAll(keepingCapacity: true)
		return [chunk]
	}

	public mutating func reset(startSample: Int = 0) {
		pending.removeAll(keepingCapacity: true)
		nextSample = max(0, startSample)
	}
}
