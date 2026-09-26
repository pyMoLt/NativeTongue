import AVFoundation
import Foundation
import HexCore
import XCTest

@testable import Hex

/// Runs only against locally installed weights and the private, local fixtures.
/// No install or network method is called by this suite.
final class EngineSmokeTests: XCTestCase {
	private let turbo = "openai_whisper-large-v3-v20240930_turbo"
	private let models = [
		"openai_whisper-large-v3-v20240930_turbo",
		"openai_whisper-large-v3",
		"parakeet-ultra-coreml",
		"parakeet-tdt-0.6b-v3-coreml",
		"qwen3-asr-1.7b-8bit-mlx",
		"canary-1b-v2-int4-coreml",
		"cohere-transcribe-2b-8bit-mlx",
		"apple-speechanalyzer-dictation",
	]

	func testInstalledEnginesProcessBothLocalRecordings() async throws {
		let literal = try loadFixture("Literal-controls.m4a")
		let terminology = try loadFixture("Terminology-de-en.m4a")
		let literalUtterances = UtteranceSegmenter.segment(literal)
		let terminologyUtterances = UtteranceSegmenter.segment(terminology)
		XCTAssertFalse(literalUtterances.isEmpty)
		XCTAssertFalse(terminologyUtterances.isEmpty)

		let client = TranscriptionClient.liveValue
		var installedCount = 0
		for model in models {
			guard await client.isModelDownloaded(model) else { continue }
			installedCount += 1
			let start = Date()
			do {
				let literalResults = try await transcribe(literal, utterances: literalUtterances, model: model, punctuation: .suppressed, client: client)
				let terminologyResults = try await transcribe(terminology, utterances: terminologyUtterances, model: model, punctuation: .natural, client: client)
				let literalText = literalResults.map(\.text).joined(separator: " ")
				let terminologyText = terminologyResults.map(\.text).joined(separator: " ")
				let kept = commandWordsKept(in: literalText)
				let automaticPunctuation = literalText.unicodeScalars.filter { CharacterSet(charactersIn: ".,;:!?").contains($0) }.count
				let memoryMB = Int((await client.processFootprintBytes() ?? 0) / 1_048_576)
				print("ENGINE_SMOKE model=\(model) literalWords=\(kept)/14 automaticPunctuation=\(automaticPunctuation) terminologyCharacters=\(terminologyText.count) seconds=\(Int(Date().timeIntervalSince(start))) processMB=\(memoryMB)")
				XCTAssertFalse(terminologyText.isEmpty, "\(model) returned empty terminology transcription")
				XCTAssertTrue(literalResults.allSatisfy(\.punctuationWasSuppressed), "\(model) did not apply the literal punctuation policy")
				XCTAssertEqual(automaticPunctuation, 0, "\(model) literal result contains automatic punctuation")
			} catch {
				XCTFail("\(model) failed local sample transcription: \(error.localizedDescription)")
			}
			await client.unloadModel()
			let loadedAfterUnload = await client.loadedModel()
			XCTAssertNil(loadedAfterUnload, "\(model) remained resident after unload")
		}
		if installedCount == 0 { throw XCTSkip("No local ASR model is installed") }
	}

	func testWhisperTurboLiteralCommandRetention() async throws {
		let samples = try loadFixture("Literal-controls.m4a")
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		let utterances = UtteranceSegmenter.segment(samples)
		let results = try await transcribe(samples, utterances: utterances, model: turbo, punctuation: .suppressed, client: client)
		let whole = try await client.transcribeSamples(samples, turbo, RequestOptions(language: "de", punctuation: .suppressed))
		await client.unloadModel()
		let text = results.map(\.text).joined(separator: " ")
		let counts = commandWordCounts(in: text)
		let punctuation = text.unicodeScalars.filter { CharacterSet(charactersIn: ".,;:!?").contains($0) }.count
		let wholePunctuation = whole.text.unicodeScalars.filter { CharacterSet(charactersIn: ".,;:!?").contains($0) }.count
		// The engine passes on the complete clip. The 12/14 segmented gap is an
		// explicit Phase-3 integration blocker, not silently waived here.
		print("SEGMENTED_COMMAND_COUNTS utterances=\(utterances.count) kept=\(counts.reduce(0) { $0 + $1.1 }) punctuation=\(punctuation)")
		print("WHOLE_COMMAND_COUNTS kept=\(commandWordsKept(in: whole.text)) punctuation=\(wholePunctuation)")
		XCTAssertEqual(commandWordsKept(in: whole.text), 14)
		XCTAssertEqual(punctuation, 0)
		XCTAssertEqual(wholePunctuation, 0)
	}

	/// Plan 5.4 acceptance on real audio through the production session path:
	/// full-recording decode → word/pause alignment → classifier → document.
	func testWhisperTurboLiteralSessionRendersExpectedDocument() async throws {
		let samples = try loadFixture("Literal-controls.m4a")
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		let runner = DictationSessionRunner(transcribeSamples: client.transcribeSamples)
		let output = try await runner.run(
			samples: samples,
			request: .init(model: turbo, mode: .literal, commandPauseMs: 450, language: "de")
		)
		await client.unloadModel()
		let expected = """
		Dies ist ein kurzer Test für Satzzeichen und Absätze.

		Erster Abschnitt: Alpha, Beta.
		Zweiter Abschnitt (Alpha-Beta)?

		Dritter Abschnitt; Abschluss, Ende.
		"""
		let paragraphs = output.text.components(separatedBy: "\n\n").count
		print("SESSION_LITERAL paragraphs=\(paragraphs) exact=\(output.text == expected) characters=\(output.text.count)")
		XCTAssertEqual(output.text, expected)
	}

	/// Plan 5.7 on real audio: terminology recording → Whisper Turbo → session
	/// pipeline with the real word packs (medical profile, literal mode).
	func testWhisperTurboTerminologyWithLexicon() async throws {
		let samples = try loadFixture("Terminology-de-en.m4a")
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		let packsDirectory = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("local-asr-docs/06-wortlisten/packs", isDirectory: true)
		let fixturePacks = URL(fileURLWithPath: "/private/tmp/LocalASR-Phase2Fixtures/packs", isDirectory: true)
		let source = FileManager.default.fileExists(atPath: fixturePacks.path) ? fixturePacks : packsDirectory
		let store = LexiconStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("lexicon-\(UUID().uuidString)"))
		defer { try? FileManager.default.removeItem(at: store.directory) }
		var ids: [String] = []
		for id in ["medical-de", "medical-en", "anatomy-la", "technical"] {
			guard let info = try? store.importPack(from: source.appendingPathComponent("\(id).json")) else { throw XCTSkip("word packs missing") }
			ids.append(info.id)
		}
		let service = LexiconService(store: store)
		let runner = DictationSessionRunner(
			transcribeSamples: client.transcribeSamples,
			corrector: { await service.corrector($0) }
		)
		let output = try await runner.run(
			samples: samples,
			request: .init(model: turbo, mode: .literal, commandPauseMs: 450, language: "de", profile: .medical, activePacks: ids)
		)
		await client.unloadModel()
		let corrections = output.document.corrections
		print("SESSION_LEXICON corrections=\(corrections.count) \(corrections.map { "\($0.original)→\($0.replacement)" })")
		let variants = output.text.split(whereSeparator: { !$0.isLetter }).filter { $0.lowercased().hasPrefix("myco") || $0.lowercased().hasPrefix("mico") }
		print("SESSION_LEXICON_MYCO \(variants)")
		let forbidden = ["anatomy", "enolic", "locale", " MIT ", " THE "]
		for word in forbidden { XCTAssertFalse(output.text.contains(word), word) }
		for term in ["Mycophenolatmofetil", "PostgreSQL", "AVFoundation"] {
			XCTAssertTrue(output.text.contains(term), "missing \(term); variants \(variants); corrections \(corrections.map { "\($0.original)→\($0.replacement)" })")
		}
	}

	/// Measures run-to-run stability of Whisper Turbo with and without the
	/// temperature fallback. Writes transcripts (test-script text, no PHI) for scoring.
	func testWhisperTurboDeterminism() async throws {
		guard ProcessInfo.processInfo.environment["LOCAL_ASR_DETERMINISM"] != nil
			|| FileManager.default.fileExists(atPath: "/private/tmp/LocalASR-Phase2Fixtures/run-determinism") else {
			throw XCTSkip("determinism measurement only on request")
		}
		let samples = try loadFixture("Terminology-de-en.m4a")
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		let output = URL(fileURLWithPath: "/private/tmp/LocalASR-Determinism", isDirectory: true)
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		defer { WhisperDecodingPolicy.temperatureFallbackCount = 0 }
		for fallback in [5, 0] {
			WhisperDecodingPolicy.temperatureFallbackCount = fallback
			for punctuation in [PunctuationPolicy.natural, .suppressed] {
				for run in 1...3 {
					let result = try await client.transcribeSamples(samples, turbo, RequestOptions(language: "de", punctuation: punctuation))
					let name = "fallback\(fallback)-\(punctuation == .natural ? "natural" : "literal")-run\(run).json"
					let json = try JSONSerialization.data(withJSONObject: ["text": result.text])
					try json.write(to: output.appendingPathComponent(name))
				}
			}
		}
		await client.unloadModel()
	}

	/// Plan acceptance F1: terminology recording as a file, speaker separation on,
	/// SRT export valid, one speaker.
	func testFileTranscriptionWithSpeakersToSRT() async throws {
		let samples = try loadFixture("Terminology-de-en.m4a")
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		let runner = FileTranscriptionRunner(transcribeSamples: client.transcribeSamples)
		let start = Date()
		var segments = try await runner.run(samples: samples, request: .init(model: turbo, mode: .normal, language: "de"))
		await client.unloadModel()
		let diarization = DiarizationClient.liveValue
		if !(await diarization.isInstalled()) { try await diarization.install { _ in } }
		let turns = try await diarization.diarize(samples)
		segments = SpeakerAssigner.normalizeOrder(SpeakerAssigner.assign(segments, turns: turns))
		let speakers = Set(segments.compactMap(\.speaker))
		let srt = TranscriptExporter.subtitles(segments, vtt: false)
		print("FILE_F1 segments=\(segments.count) speakers=\(speakers.count) turns=\(turns.count) seconds=\(Int(Date().timeIntervalSince(start)))")
		XCTAssertGreaterThan(segments.count, 5)
		XCTAssertEqual(speakers.count, 1)
		XCTAssertTrue(srt.hasPrefix("1\n00:00:"))
		XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
		XCTAssertLessThanOrEqual(segments.last?.end ?? 0, Double(samples.count) / 16_000 + 0.5)
	}

	func testIdleUnloadFiresAndInvalidatesPreviousTimer() async throws {
		let client = TranscriptionClientLive(idleUnloadDelayForTesting: .milliseconds(500))
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		await client.configureIdleUnload(minutes: 2)
		try await client.prewarm(model: turbo)
		var loaded = await client.loadedModelName()
		XCTAssertEqual(loaded, turbo)

		try await Task.sleep(for: .milliseconds(300))
		try await client.prewarm(model: turbo) // restarts the timer and invalidates its old generation
		try await Task.sleep(for: .milliseconds(300))
		loaded = await client.loadedModelName()
		XCTAssertEqual(loaded, turbo, "The earlier timer must not unload a recently reused model")

		try await Task.sleep(for: .milliseconds(300))
		loaded = await client.loadedModelName()
		XCTAssertNil(loaded, "The refreshed idle timer should unload the model")
	}

	func testTranscriptionWaitsForHotkeyPrewarmToFinish() async throws {
		let client = TranscriptionClientLive()
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		await client.configureIdleUnload(minutes: 0)
		let prewarm = Task { try await client.prewarm(model: turbo) }
		try await Task.sleep(for: .milliseconds(50))
		let transcription = Task {
			try await client.transcribe(
				samples: Array(repeating: 0, count: 16_000),
				model: turbo,
				options: RequestOptions(language: "de", punctuation: .suppressed)
			)
		}
		try await prewarm.value
		_ = try await transcription.value
		let loaded = await client.loadedModelName()
		XCTAssertEqual(loaded, turbo)
		await client.unloadModel()
	}

	private func transcribe(
		_ samples: [Float],
		utterances: [Utterance],
		model: String,
		punctuation: PunctuationPolicy,
		client: TranscriptionClient
	) async throws -> [EngineResult] {
		var results: [EngineResult] = []
		for utterance in utterances {
			let clip = Array(samples[utterance.range])
			let result = try await client.transcribeSamples(
				clip,
				model,
				RequestOptions(language: "de", punctuation: punctuation)
			)
			results.append(result)
		}
		return results
	}

	private func commandWordsKept(in text: String) -> Int {
		commandWordCounts(in: text).reduce(0) { $0 + $1.1 }
	}

	private func commandWordCounts(in text: String) -> [(String, Int)] {
		let expected: [(String, Int)] = [
			("neuer absatz", 2), ("neue zeile", 1), ("doppelpunkt", 1),
			("komma", 2), ("punkt", 3), ("klammer auf", 1),
			("klammer zu", 1), ("bindestrich", 1), ("fragezeichen", 1), ("semikolon", 1),
		]
		return expected.map { entry in
			let pattern = "(?<![\\p{L}])\(NSRegularExpression.escapedPattern(for: entry.0))(?![\\p{L}])"
			let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
			return (entry.0, min(regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), entry.1))
		}
	}

	private func loadFixture(_ name: String) throws -> [Float] {
		let fixtureDirectory: URL
		if let override = ProcessInfo.processInfo.environment["LOCAL_ASR_TEST_AUDIO_DIR"] {
			fixtureDirectory = URL(fileURLWithPath: override, isDirectory: true)
		} else if FileManager.default.fileExists(atPath: "/private/tmp/LocalASR-Phase2Fixtures") {
			// Xcode does not forward the caller's environment to its app test host.
			// Keep private recordings out of the app bundle and Desktop TCC path.
			fixtureDirectory = URL(fileURLWithPath: "/private/tmp/LocalASR-Phase2Fixtures", isDirectory: true)
		} else {
			let root = URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent() // HexTests
				.deletingLastPathComponent() // hex-fork
				.deletingLastPathComponent() // Local_ASR
			fixtureDirectory = root.appendingPathComponent("local-asr-docs/04-tests/audio", isDirectory: true)
		}
		let url = fixtureDirectory.appendingPathComponent(name)
		guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private audio fixture missing") }
		let file = try AVAudioFile(forReading: url)
		let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
		let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
		let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
		try file.read(into: input)
		let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1_024
		let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
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
