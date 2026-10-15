import AVFoundation
import XCTest
@testable import HexCore

final class UtteranceSegmenterTests: XCTestCase {
	private let rate = 16_000

	private func tone(_ ms: Int, amplitude: Float = 0.2) -> [Float] {
		(0..<(ms * rate / 1_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
	}

	private func silence(_ ms: Int, noise: Float = 0.0005) -> [Float] {
		var generator = SystemRandomNumberGenerator()
		return (0..<(ms * rate / 1_000)).map { _ in Float.random(in: -noise...noise, using: &generator) }
	}

	func testSplitsOnPausesLongerThanMinimum() {
		let audio = silence(1_200) + tone(800) + silence(700) + tone(600) + silence(300) + tone(500) + silence(900)
		let utterances = UtteranceSegmenter.segment(audio)
		XCTAssertEqual(utterances.count, 2, "300 ms is below the 450 ms pause and must not split")
		XCTAssertEqual(utterances[0].pauseBeforeMs, Int.max)
		XCTAssertGreaterThanOrEqual(utterances[1].pauseBeforeMs, 650)
		XCTAssertLessThanOrEqual(utterances[1].pauseBeforeMs, 760)
		XCTAssertEqual(utterances[0].pauseAfterMs, utterances[1].pauseBeforeMs)
		XCTAssertGreaterThanOrEqual(utterances[1].pauseAfterMs ?? 0, 450, "trailing silence is measured")
	}

	func testRecordingEndingMidSpeechHasOpenPauseAfter() {
		let utterances = UtteranceSegmenter.segment(silence(1_200) + tone(900))
		XCTAssertEqual(utterances.count, 1)
		XCTAssertEqual(utterances[0].pauseAfterMs, Int.max)
	}

	func testDropsShortBlips() {
		let audio = silence(1_200) + tone(80) + silence(900) + tone(700) + silence(800)
		let utterances = UtteranceSegmenter.segment(audio)
		XCTAssertEqual(utterances.count, 1)
		XCTAssertEqual(utterances[0].pauseBeforeMs, Int.max, "a dropped blip is not a previous utterance")
	}

	func testSplitsVeryLongSpeechWithoutPauseBoundary() {
		var config = SegmenterConfig()
		config.maxUtteranceMs = 3_000
		let audio = silence(1_200) + tone(7_000) + silence(900)
		let utterances = UtteranceSegmenter.segment(audio, config: config)
		XCTAssertGreaterThanOrEqual(utterances.count, 2)
		XCTAssertEqual(utterances[1].pauseBeforeMs, 0, "forced splits must never look like a command pause")
		XCTAssertEqual(utterances[0].pauseAfterMs, 0)
	}

	func testStreamingMatchesBatch() {
		let audio = silence(1_200) + tone(800) + silence(700) + tone(600) + silence(900)
		var segmenter = UtteranceSegmenter()
		var closed: [Utterance] = []
		for start in stride(from: 0, to: audio.count, by: 2_048) {
			for case let .utteranceClosed(u) in segmenter.append(audio[start..<min(start + 2_048, audio.count)]) {
				closed.append(u)
			}
		}
		for case let .utteranceClosed(u) in segmenter.finish() { closed.append(u) }
		let batch = UtteranceSegmenter.segment(audio)
		XCTAssertEqual(closed.map(\.range), batch.map(\.range))
	}

	/// Acceptance test from the V2 plan (5.1): the three structural commands in the
	/// user's literal recording must each be an isolated utterance with a measured
	/// pause ≥ 450 ms before and after. Skipped when the private fixture is absent.
	func testLiteralRecordingIsolatesStructuralCommands() throws {
		let loaded = try TestAudio.load("Literal-controls.m4a")
		let samples = try XCTUnwrap(loaded, "fixture missing")
		let utterances = UtteranceSegmenter.segment(samples)
		func seconds(_ sample: Int) -> Double { Double(sample) / 16_000 }
		// Speech regions of the commands measured in the benchmark (energy VAD).
		let commands: [(name: String, start: Double, end: Double)] = [
			("Neuer Absatz", 5.66, 6.56),
			("Neue Zeile", 13.08, 13.94),
			("Neuer Absatz", 22.02, 23.20),
		]
		for command in commands {
			let match = utterances.first {
				seconds($0.range.lowerBound) <= command.start + 0.35 && seconds($0.range.upperBound) >= command.end - 0.35
					&& seconds($0.range.lowerBound) >= command.start - 0.6 && seconds($0.range.upperBound) <= command.end + 0.6
			}
			let utterance = try XCTUnwrap(match, "\(command.name) at \(command.start)s is not an isolated utterance: \(utterances.map { (seconds($0.range.lowerBound), seconds($0.range.upperBound)) })")
			XCTAssertGreaterThanOrEqual(utterance.pauseBeforeMs, 450, command.name)
			XCTAssertGreaterThanOrEqual(utterance.pauseAfterMs ?? 0, 450, command.name)
		}
	}
}

enum TestAudio {
	/// Loads a private fixture from `dev-docs/04-tests/audio` as 16 kHz mono Float32.
	/// Throws `XCTSkip` when the file is not present (fixtures are not in git).
	static func load(_ name: String) throws -> [Float]? {
		let root = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent() // Dictation
			.deletingLastPathComponent() // HexCoreTests
			.deletingLastPathComponent() // Tests
			.deletingLastPathComponent() // HexCore
			.deletingLastPathComponent() // NativeTongue
			.deletingLastPathComponent() // Local_ASR
		let devDocsURL = root.appendingPathComponent("dev-docs/04-tests/audio/\(name)")
		let legacyURL = root.appendingPathComponent("dev-docs/04-tests/audio/\(name)")
		let url = FileManager.default.fileExists(atPath: devDocsURL.path) ? devDocsURL : legacyURL
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw XCTSkip("Private audio fixture \(name) not available")
		}
		let file = try AVAudioFile(forReading: url)
		let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
		let converter = AVAudioConverter(from: file.processingFormat, to: target)!
		let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
		try file.read(into: input)
		let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1_024
		let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
		var consumed = false
		var error: NSError?
		converter.convert(to: output, error: &error) { _, status in
			if consumed { status.pointee = .endOfStream; return nil }
			consumed = true
			status.pointee = .haveData
			return input
		}
		if let error { throw error }
		return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
	}
}
