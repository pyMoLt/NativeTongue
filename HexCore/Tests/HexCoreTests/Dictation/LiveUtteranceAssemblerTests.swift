import XCTest
@testable import HexCore

final class LiveUtteranceAssemblerTests: XCTestCase {
	func testLiveChunksProducePauseDelimitedAudioSlicesAndPauseRefinements() throws {
		let samples = [Float](repeating: 0, count: 3_200)
			+ tone(sampleCount: 6_400)
			+ [Float](repeating: 0, count: 9_600)
			+ tone(sampleCount: 4_800)
			+ [Float](repeating: 0, count: 8_000)
		var chunker = AudioChunker(chunkSize: 2_048)
		var assembler = LiveUtteranceAssembler(config: SegmenterConfig(minPauseMs: 450))
		var events: [LiveUtteranceEvent] = []

		for chunk in chunker.append(samples) {
			events += try assembler.append(chunk)
		}
		for chunk in chunker.finish() {
			events += try assembler.append(chunk)
		}
		events += try assembler.finish()

		let ready = events.compactMap { event -> (Utterance, [Float])? in
			guard case let .utteranceReady(utterance, audio) = event else { return nil }
			return (utterance, audio)
		}
		XCTAssertEqual(ready.count, 2)
		XCTAssertEqual(ready.map { $0.0.id }, [0, 1])
		XCTAssertTrue(ready.allSatisfy { $0.0.range.count == $0.1.count && !$0.1.isEmpty })
		XCTAssertTrue(events.contains(.pauseAfterKnown(id: 0, milliseconds: 600)))
	}

	func testSampleGapFailsInsteadOfPretendingLiveAudioIsComplete() throws {
		var assembler = LiveUtteranceAssembler()
		_ = try assembler.append(AudioChunk(samples: [Float](repeating: 0, count: 2_048), startSample: 0))

		XCTAssertThrowsError(
			try assembler.append(AudioChunk(samples: [Float](repeating: 0, count: 2_048), startSample: 4_096))
		) { error in
			XCTAssertEqual(error as? LiveUtteranceAssemblyError, .sampleGap(expected: 2_048, received: 4_096))
		}
	}

	private func tone(sampleCount: Int) -> [Float] {
		(0..<sampleCount).map { index in
			0.2 * sin(2 * .pi * 440 * Float(index) / 16_000)
		}
	}
}
