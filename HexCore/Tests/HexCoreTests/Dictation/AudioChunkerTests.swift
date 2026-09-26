import XCTest
@testable import HexCore

final class AudioChunkerTests: XCTestCase {
	func testAppendEmitsFixedChunksWithContiguousSampleOffsets() {
		var chunker = AudioChunker(chunkSize: 4)

		XCTAssertTrue(chunker.append([0, 1, 2]).isEmpty)
		let chunks = chunker.append([3, 4, 5, 6, 7, 8])

		XCTAssertEqual(chunks, [
			AudioChunk(samples: [0, 1, 2, 3], startSample: 0),
			AudioChunk(samples: [4, 5, 6, 7], startSample: 4),
		])
		XCTAssertEqual(chunker.finish(), [AudioChunk(samples: [8], startSample: 8)])
		XCTAssertTrue(chunker.finish().isEmpty)
	}

	func testResetDropsPendingSamplesAndSetsNewTimelineOrigin() {
		var chunker = AudioChunker(chunkSize: 3)
		_ = chunker.append([1, 2])

		chunker.reset(startSample: 120)

		XCTAssertEqual(
			chunker.append([3, 4, 5]),
			[AudioChunk(samples: [3, 4, 5], startSample: 120)]
		)
	}
}
