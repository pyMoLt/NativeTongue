import AudioCommon
import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import LocalLLM
import Qwen3ASR
import XCTest

@testable import Hex

/// Runs only against locally installed weights and the private, local fixtures.
/// No install or network method is called by this suite.
final class EngineSmokeTests: XCTestCase {
	private let turbo = "openai_whisper-large-v3-v20240930_turbo"
	/// Optional filter file (Xcode does not pass environment variables to the test host).
	private var models: [String] {
		let filter = (try? String(contentsOfFile: "/private/tmp/LocalASR-Phase2Fixtures/only-model", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
		return filter.map { [$0] } ?? allModels
	}
	private let allModels = [
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
				Self.metric("ENGINE_SMOKE model=\(model) literalWords=\(kept)/14 automaticPunctuation=\(automaticPunctuation) seconds=\(Int(Date().timeIntervalSince(start))) processMB=\(memoryMB)")
				print("ENGINE_SMOKE model=\(model) literalWords=\(kept)/14 automaticPunctuation=\(automaticPunctuation) terminologyCharacters=\(terminologyText.count) seconds=\(Int(Date().timeIntervalSince(start))) processMB=\(memoryMB)")
				XCTAssertFalse(terminologyText.isEmpty, "\(model) returned empty terminology transcription")
				XCTAssertTrue(literalResults.allSatisfy(\.punctuationWasSuppressed), "\(model) did not apply the literal punctuation policy")
				XCTAssertEqual(automaticPunctuation, 0, "\(model) literal result contains automatic punctuation")
			} catch {
				XCTFail("\(model) failed local sample transcription: \(error.localizedDescription)")
			}
			await client.unloadModel()
			try? await Task.sleep(for: .seconds(2))
			let afterUnloadMB = Int((await client.processFootprintBytes() ?? 0) / 1_048_576)
			let mlx = MLXMemoryControl.usage()
			Self.metric("ENGINE_MEMORY model=\(model) afterUnloadMB=\(afterUnloadMB) mlxActiveMB=\(mlx.active / 1_048_576) mlxCacheMB=\(mlx.cache / 1_048_576)")
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
			.appendingPathComponent("dev-docs/06-wortlisten/packs", isDirectory: true)
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

	/// Same production path as Normal direct dictation and the dictation box;
	/// keep complete outputs for WER and technical/medical term scoring.
	func testNormalTerminologyAccuracyReport() async throws {
		let samples = try loadFixture("Terminology-de-en.m4a")
		let client = TranscriptionClient.liveValue
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let packSource = root.appendingPathComponent("dev-docs/06-wortlisten/packs", isDirectory: true)
		let store = LexiconStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("accuracy-lexicon-\(UUID().uuidString)"))
		defer { try? FileManager.default.removeItem(at: store.directory) }
		var packs: [String] = []
		for id in ["technical", "medical-de", "anatomy-la"] {
			let url = packSource.appendingPathComponent("\(id).json")
			if FileManager.default.fileExists(atPath: url.path) { packs.append(try store.importPack(from: url).id) }
		}
		let service = LexiconService(store: store)
		let runner = DictationSessionRunner(transcribeSamples: client.transcribeSamples,
			corrector: { await service.corrector($0) })
		let report = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003", isDirectory: true)
		try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
		var tested = 0
		for model in [turbo, "parakeet-ultra-coreml"] where await client.isModelDownloaded(model) {
			let started = Date()
			let output = try await runner.run(samples: samples, request: .init(
				model: model, mode: .normal, commandPauseMs: 450, language: "de",
				profile: .medical, activePacks: packs
			))
			try output.text.write(to: report.appendingPathComponent("batch-\(model).txt"), atomically: true, encoding: .utf8)
			print("ACCURACY_BATCH model=\(model) seconds=\(Int(Date().timeIntervalSince(started))) words=\(output.text.split(separator: " ").count) corrections=\(output.document.corrections.count)")
			XCTAssertGreaterThan(output.text.count, 500)
			tested += 1
			await client.unloadModel()
		}
		if tested == 0 { throw XCTSkip("No selected local ASR engine is installed") }
	}

	func testRealFileTranscriptionExportsTimedSRTWithoutDownload() async throws {
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		let samples = try loadFixture("Terminology-de-en.m4a")
		let runner = FileTranscriptionRunner(transcribeSamples: client.transcribeSamples)
		let segments = try await runner.run(samples: samples, request: .init(model: turbo, mode: .normal, language: "de"))
		await client.unloadModel()
		let srt = TranscriptExporter.subtitles(segments, vtt: false)
		let report = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/file-terminology.srt")
		try srt.write(to: report, atomically: true, encoding: .utf8)
		XCTAssertGreaterThan(segments.count, 5)
		XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
		XCTAssertTrue(srt.hasPrefix("1\n00:00:"))
		XCTAssertLessThanOrEqual(segments.last?.end ?? 0, Double(samples.count) / 16_000 + 0.5)
	}

	/// Ablates each production stage on the same real recordings. The personal
	/// aliases are held in memory and never change the user's own vocabulary.
	func testRealAudioPipelineAblationsWithAndWithoutAutomaticAI() async throws {
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		guard let ai = LLMModelCatalog.preferredInstalledForTests() else { throw XCTSkip("No AI model installed") }
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let packRoot = root.appendingPathComponent("dev-docs/06-wortlisten/packs", isDirectory: true)
		let packs = try ["technical", "medical-de", "anatomy-la"].map { id in
			try JSONDecoder().decode(LexiconPack.self, from: Data(contentsOf: packRoot.appendingPathComponent("\(id).json")))
		}
		let packIndex = LexiconIndex(packs: packs)
		let aliases: [(String, [String])] = [
			("Mycophenolatmofetil", ["Mycophenolatmophetil", "mycophenolat morphetil"]),
			("Rivaroxaban", ["Ribaroxaban"]),
			("Glomerulonephritis", ["Clomerulonephritis", "klomerulonephritis"]),
			("Urothelkarzinom", ["Urotelkarzinom", "uroT-Karzinum"]),
			("Pembrolizumab", ["Pemprolizumab", "pemprolizumap"]),
			("Jejunum", ["Iunum"]),
			("Tinea corporis", ["Tiniacorpores", "tinia corporis"]),
			("Musculus vastus lateralis", ["Maskulus vastus lateralis", "Masculus vastus lateralis"]),
			("ST-Hebungsinfarkt", ["ST Hebungsinfarkt", "ST Hebungs Infarkt"]),
		]
		let userEntries = aliases.map { term, variants in
			LexiconEntry(term: term, lang: "de", category: "user", aliases: variants, autoReplace: true, profile: .medical)
		}
		let userIndex = LexiconIndex(userEntries: userEntries)
		let report = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/ablation", isDirectory: true)
		try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
		let cases: [(String, String, DictationMode, String)] = [
			("terminology-normal", "Terminology-de-en.m4a", .normal, turbo),
			("terminology-literal", "Terminology-de-en.m4a", .literal, turbo),
			("commands-normal", "Literal-controls.m4a", .normal, turbo),
			("commands-literal", "Literal-controls.m4a", .literal, turbo),
			("commands-normal-parakeet", "Literal-controls.m4a", .normal, "parakeet-ultra-coreml"),
		]
		let stages: [(String, Bool, Bool, Bool)] = [
			("structure", false, false, false),
			("format", true, false, false),
			("pack", false, true, false),
			("personal", false, false, true),
			("full", true, true, true),
		]
		let llm = LLMHost()
		for (label, recording, mode, model) in cases where await client.isModelDownloaded(model) {
			let samples = try loadFixture(recording)
			let raw = try await client.transcribeSamples(samples, model, RequestOptions(
				language: "de", punctuation: mode == .literal ? .suppressed : .natural
			))
			try raw.text.write(to: report.appendingPathComponent("\(label)-asr.txt"), atomically: true, encoding: .utf8)
			var stageRawText: String?
			for (stage, format, usePack, useUser) in stages {
				let indexes = (useUser ? [userIndex] : []) + (usePack ? [packIndex] : [])
				let runner = DictationSessionRunner(transcribeSamples: client.transcribeSamples, corrector: { context in
					guard !indexes.isEmpty else { return nil }
					return LexiconCorrector(indexes: indexes, wordChecker: SystemWordChecker.shared,
						options: .init(mode: context.mode, language: context.language, profile: context.profile,
						               autoReplacePackTermsInLiteral: context.autoReplacePackTermsInLiteral))
				})
				let output = try await runner.run(samples: samples, request: .init(
					model: model, mode: mode, commandPauseMs: 450, language: "de", profile: .medical,
					activePacks: usePack ? packs.map(\.id) : [], formatNumbers: format,
					agentFormatting: format, boxOpen: false
				))
				if let stageRawText { XCTAssertEqual(output.rawText, stageRawText, "ASR changed across \(label) ablation stages") }
				else { stageRawText = output.rawText }
				try output.rawText.write(to: report.appendingPathComponent("\(label)-\(stage)-raw.txt"), atomically: true, encoding: .utf8)
				try output.text.write(to: report.appendingPathComponent("\(label)-\(stage).txt"), atomically: true, encoding: .utf8)
				print("ABLATION case=\(label) stage=\(stage) chars=\(output.text.count) corrections=\(output.document.corrections.count)")
				XCTAssertFalse(output.text.isEmpty)
				guard stage == "full" else { continue }
				var settings = HexSettings()
				settings.dictationMode = mode
				settings.dictationBoxEnabledLiteral = false
				settings.postProcessing.enabled = true
				settings.postProcessing.autoEnabled = true
				settings.postProcessing.autoScope = .normalAndLiteralWithoutBox
				let aiRequest = try XCTUnwrap(TranscriptionFeature.automaticPolish(for: output.text, settings: settings))
				let protected = userEntries.map(\.term).filter { output.text.localizedCaseInsensitiveContains($0) }
				let request = PolishRequest(text: aiRequest.text, mode: aiRequest.mode, modelID: aiRequest.modelID,
				                            settings: aiRequest.settings, protectedTerms: protected)
				let polished = await llm.polish(request, keepAIResultOnIssues: false, onText: nil)
				try polished.text.write(to: report.appendingPathComponent("\(label)-full-ai.txt"), atomically: true, encoding: .utf8)
				try ("failed=\(polished.failed) issues=\(polished.issues)\nAI=\(polished.aiText ?? "-")\n")
					.write(to: report.appendingPathComponent("\(label)-full-ai-meta.txt"), atomically: true, encoding: .utf8)
				print("ABLATION case=\(label) stage=full-ai changed=\(polished.text != output.text) failed=\(polished.failed) issues=\(polished.issues.count)")
			}
		}
		await llm.unload()
		await client.unloadModel()
	}

	@MainActor
	func testRealLiteralAudioThroughDictationBoxAIAndPaste() async throws {
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		guard let ai = LLMModelCatalog.descriptor(id: "qwen35-2b-8bit", settings: PostProcessingSettings()),
		      LLMModelInstaller.isInstalled(repository: ai.repository, baseDirectory: LLMHost.baseDirectory)
		else { throw XCTSkip("Qwen 2B is not installed") }
		let samples = try loadFixture("Literal-controls.m4a")
		let runner = DictationSessionRunner(transcribeSamples: client.transcribeSamples)
		let output = try await runner.run(samples: samples, request: .init(model: turbo, mode: .literal, commandPauseMs: 450, language: "de"))
		await client.unloadModel()
		var settings = HexSettings()
		settings.postProcessing.enabled = true
		settings.postProcessing.boxModel = "qwen35-2b-8bit"
		var state = DictationBoxFeature.State(hexSettings: Shared(value: settings))
		state.isPresented = true
		state.mode = .literal
		let pasted = LockIsolated<[RichPastePayload]>([])
		let llm = LLMClient.liveValue
		let store = TestStore(initialState: state) { DictationBoxFeature() } withDependencies: {
			$0.llm = llm
			$0.lexicon.userLexicon = { UserLexicon() }
			$0.pasteboard.pasteRich = { payload in pasted.withValue { $0.append(payload) } }
		}
		store.exhaustivity = .off
		let audio = FileManager.default.temporaryDirectory.appendingPathComponent("box-real-\(UUID().uuidString).wav")
		try Data([0]).write(to: audio)
		await store.send(.dictationFinished(output, audio))
		let before = store.state.text.string
		await store.send(.aiTapped(.clean))
		await store.receive(\.aiFinished, timeout: .seconds(60))
		let after = store.state.text.string
		let report = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003", isDirectory: true)
		try before.write(to: report.appendingPathComponent("box-literal-ai-off.txt"), atomically: true, encoding: .utf8)
		try after.write(to: report.appendingPathComponent("box-literal-ai-on.txt"), atomically: true, encoding: .utf8)
		XCTAssertFalse(after.isEmpty)
		await store.send(.confirmTapped)
		await store.receive(\.close)
		XCTAssertEqual(pasted.value.first?.plain, after)
		XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
	}

	/// Locally synthesized speech is a supplemental probe for spoken values and
	/// filenames absent from the two human recordings; no model is downloaded.
	func testSyntheticValuesAndIdentifiersThroughBatchAndStreaming() async throws {
		let source = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/spoken-values-identifiers.aiff")
		guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Local TTS probe missing") }
		let client = TranscriptionClient.liveValue
		guard await client.isModelDownloaded(turbo) else { throw XCTSkip("Whisper Turbo not installed") }
		let samples = try AudioFileLoader.load(url: source, targetSampleRate: 16_000)
		let report = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/values-ablation", isDirectory: true)
		try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
		let stages: [(String, Bool, Bool)] = [
			("off", false, false), ("numbers", true, false),
			("code", false, true), ("full", true, true),
		]
		let runner = DictationSessionRunner(transcribeSamples: client.transcribeSamples)
		for mode in [DictationMode.normal, .literal] {
			for (name, numbers, code) in stages {
				let result = try await runner.run(samples: samples, request: .init(
					model: turbo, mode: mode, commandPauseMs: 450, language: "de",
					formatNumbers: numbers, agentFormatting: code
				))
				try result.text.write(to: report.appendingPathComponent("batch-\(mode.rawValue)-\(name).txt"), atomically: true, encoding: .utf8)
				XCTAssertFalse(result.text.isEmpty)
			}
		}
		let model = turbo
		let engine = EmulatedStreamingEngine(pauseMs: 600, maxBlockSeconds: 12) { block in
			try await client.transcribeSamples(block, model, RequestOptions(language: "de", punctuation: .suppressed)).text
		}
		try await engine.begin(language: "de")
		var deltas: [String] = []
		var index = 0
		while index < samples.count {
			let end = min(index + 1_600, samples.count)
			let update = try await engine.feed(Array(samples[index..<end]))
			if !update.committed.isEmpty { deltas.append(update.committed) }
			index = end
		}
		let last = try await engine.end().committed
		if !last.isEmpty { deltas.append(last) }
		try deltas.joined().write(to: report.appendingPathComponent("streaming-asr.txt"), atomically: true, encoding: .utf8)
		for (name, numbers, code) in stages {
			var settings = StreamingSettings()
			settings.punctuationMode = .literal
			settings.literalScope = .extended
			settings.formatNumbers = numbers
			settings.codeFormatting = code
			var processor = StreamingTextProcessor(options: .init(settings: settings, language: "de", englishCommands: true, aliases: [:]))
			var output = ""
			for delta in deltas { output += processor.push(delta) }
			output += processor.flush()
			try output.write(to: report.appendingPathComponent("streaming-literal-\(name).txt"), atomically: true, encoding: .utf8)
			XCTAssertFalse(output.isEmpty)
		}
		await client.unloadModel()
	}

	func testSyntheticValuesWithParakeetUltraForLiteralTokens() async throws {
		let source = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/spoken-values-identifiers.aiff")
		guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Local TTS probe missing") }
		let client = TranscriptionClient.liveValue
		let model = "parakeet-ultra-coreml"
		guard await client.isModelDownloaded(model) else { throw XCTSkip("Parakeet Ultra not installed") }
		let samples = try AudioFileLoader.load(url: source, targetSampleRate: 16_000)
		let report = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/values-ablation", isDirectory: true)
		let runner = DictationSessionRunner(transcribeSamples: client.transcribeSamples)
		for (stage, numbers, code) in [("off", false, false), ("numbers", true, false),
		                               ("code", false, true), ("full", true, true)] {
			let output = try await runner.run(samples: samples, request: .init(
				model: model, mode: .literal, commandPauseMs: 450, language: "de",
				formatNumbers: numbers, agentFormatting: code
			))
			try output.text.write(to: report.appendingPathComponent("parakeet-literal-\(stage).txt"), atomically: true, encoding: .utf8)
			XCTAssertFalse(output.text.isEmpty)
		}
		let engine = EmulatedStreamingEngine(pauseMs: 600, maxBlockSeconds: 12) { block in
			try await client.transcribeSamples(block, model, RequestOptions(language: "de", punctuation: .suppressed)).text
		}
		try await engine.begin(language: "de")
		var deltas: [String] = []
		var index = 0
		while index < samples.count {
			let end = min(index + 1_600, samples.count)
			let update = try await engine.feed(Array(samples[index..<end]))
			if !update.committed.isEmpty { deltas.append(update.committed) }
			index = end
		}
		let last = try await engine.end().committed
		if !last.isEmpty { deltas.append(last) }
		try deltas.joined().write(to: report.appendingPathComponent("parakeet-streaming-asr.txt"), atomically: true, encoding: .utf8)
		for (stage, numbers, code) in [("off", false, false), ("numbers", true, false),
		                               ("code", false, true), ("full", true, true)] {
			var settings = StreamingSettings()
			settings.punctuationMode = .literal
			settings.formatNumbers = numbers
			settings.codeFormatting = code
			var processor = StreamingTextProcessor(options: .init(settings: settings, language: "de", englishCommands: true, aliases: [:]))
			var output = ""
			for delta in deltas { output += processor.push(delta) }
			output += processor.flush()
			try output.write(to: report.appendingPathComponent("parakeet-streaming-\(stage).txt"), atomically: true, encoding: .utf8)
		}
		await client.unloadModel()
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

	/// Metrics only (no transcript text) for the test report.
	static func metric(_ line: String) {
		let url = URL(fileURLWithPath: "/private/tmp/LocalASR-Metrics.txt")
		let data = Data((line + "\n").utf8)
		if let handle = try? FileHandle(forWritingTo: url) {
			handle.seekToEndOfFile(); handle.write(data); try? handle.close()
		} else {
			try? data.write(to: url)
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
			fixtureDirectory = root.appendingPathComponent("dev-docs/04-tests/audio", isDirectory: true)
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
