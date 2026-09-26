import XCTest
@testable import HexCore

final class LiveTranscriptionSchedulerTests: XCTestCase {
	func testClosedUtterancesAreTranscribedInOrderAndPauseIsRefined() async throws {
		let samples = [Float](repeating: 0, count: 3_200)
			+ tone(sampleCount: 6_400)
			+ [Float](repeating: 0, count: 9_600)
			+ tone(sampleCount: 4_800)
			+ [Float](repeating: 0, count: 8_000)
		var chunker = AudioChunker(chunkSize: 2_048)
		let scheduler = LiveTranscriptionScheduler(config: SegmenterConfig(minPauseMs: 450))
		let probe = LiveSchedulerProbe()
		var events: [LiveTranscriptionEvent] = []

		for chunk in chunker.append(samples) {
			events += try await scheduler.append(chunk) { samples in
				try await probe.transcribe(samples)
			}
		}
		for chunk in chunker.finish() {
			events += try await scheduler.append(chunk) { samples in
				try await probe.transcribe(samples)
			}
		}
		events += try await scheduler.finish { samples in
			try await probe.transcribe(samples)
		}

		let utterances = events.compactMap { event -> AlignedUtterance? in
			guard case let .utteranceTranscribed(utterance) = event else { return nil }
			return utterance
		}
		XCTAssertEqual(utterances.map(\.text), ["utterance-0", "utterance-1"])
		XCTAssertEqual(utterances.map { $0.utterance.id }, [0, 1])
		XCTAssertTrue(events.contains(.pauseAfterKnown(id: 0, milliseconds: 600)))
		let callCount = await probe.callCount()
		XCTAssertEqual(callCount, 2)
	}

	private func tone(sampleCount: Int) -> [Float] {
		(0..<sampleCount).map { index in
			0.2 * sin(2 * .pi * 440 * Float(index) / 16_000)
		}
	}
}

private actor LiveSchedulerProbe {
	private var count = 0

	func transcribe(_ samples: [Float]) async throws -> EngineResult {
		let ordinal = count
		count += 1
		XCTAssertFalse(samples.isEmpty)
		return EngineResult(text: "utterance-\(ordinal)", detectedLanguage: "de")
	}

	func callCount() -> Int { count }
}
