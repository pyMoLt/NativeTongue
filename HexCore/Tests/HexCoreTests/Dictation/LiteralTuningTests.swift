import XCTest
@testable import HexCore

/// Literal fine-tuning for Whisper and Qwen (test matrix 15.10.2026).
final class LiteralTuningTests: XCTestCase {
	/// Runs aligned utterances (text, pause before, pause after, word gaps) through `makeDocument`.
	private func run(_ items: [(String, Int, Int, [Int?]?)], tuning: LiteralTuning?, mode: DictationMode = .literal, commandPauseMs: Int = 250) -> String {
		let aligned = items.enumerated().map { index, item in
			AlignedUtterance(utterance: Utterance(id: index, range: index * 64_000 ..< index * 64_000 + 48_000, pauseBeforeMs: item.1, pauseAfterMs: item.2),
			                 text: item.0, wordGapsMs: item.3)
		}
		var options = DictationSessionOptions(mode: mode, commandPauseMs: commandPauseMs, resolveSelfCorrections: true)
		options.literalTuning = tuning
		return DictationSessionProcessor.makeDocument(from: aligned, options: options)
			.render(AssemblerOptions(language: "de", mode: mode))
	}

	private func one(_ text: String, tuning: LiteralTuning? = .whisper) -> String {
		run([(text, Int.max, Int.max, nil)], tuning: tuning)
	}

	// MARK: Article rule

	func testVerbParticleBeforePunktIsAPeriod() {
		XCTAssertEqual(one("Bitte bring Kleber mit Punkt Danke Punkt"), "Bitte bring Kleber mit. Danke.")
		// Without fine-tuning the old rule keeps „mit Punkt“ as words.
		XCTAssertEqual(one("Bitte bring Kleber mit Punkt", tuning: nil), "Bitte bring Kleber mit Punkt")
	}

	func testArticlesStillMakeMarkWordsWords() {
		XCTAssertEqual(one("Setz hier einen Punkt Punkt"), "Setz hier einen Punkt.")
	}

	func testOnOffSwitchAndTimeWord() {
		XCTAssertEqual(one("Der Ein Schrägstrich Aus Schalter funktioniert Punkt"), "Der Ein/Aus Schalter funktioniert.")
		XCTAssertEqual(one("Wir treffen uns um Punkt acht Uhr Punkt"), "Wir treffen uns um Punkt 8 Uhr.")
	}

	// MARK: Structural commands

	func testStructuralCommandNeedsOnlyThePauseBefore() {
		// „Neuer Absatz“ spoken after a 400 ms pause, directly followed by text.
		let text = "Ende Punkt Neuer Absatz Weiter geht es Punkt"
		let gaps: [Int?] = [nil, 0, 400, 0, 80, 0, 0, 0]
		XCTAssertEqual(run([(text, Int.max, Int.max, gaps)], tuning: .whisper), "Ende.\n\nWeiter geht es.")
		XCTAssertEqual(run([(text, Int.max, Int.max, gaps)], tuning: nil), "Ende. Neuer Absatz Weiter geht es.")
	}

	func testStructuralCommandWithoutTimingsForQwen() {
		XCTAssertEqual(one("Ende Punkt Neuer Absatz Weiter geht es Punkt", tuning: .qwen), "Ende.\n\nWeiter geht es.")
		// Whisper needs the measured pause …
		XCTAssertEqual(one("Das ist ein neuer Absatz im Text Punkt", tuning: .whisper), "Das ist ein neuer Absatz im Text.")
		// … or a spoken mark right before the command.
		XCTAssertEqual(one("Projektnotiz Doppelpunkt Neuer Absatz Der Patient Punkt", tuning: .whisper), "Projektnotiz:\n\nDer Patient.")
	}

	func testEngineDigitsAroundSpokenCommands() {
		XCTAssertEqual(one("Die Dosis beträgt 2 Komma 5 Milligramm Punkt"), "Die Dosis beträgt 2,5 mg.")
		XCTAssertEqual(one("Er kam am 3 März Punkt"), "Er kam am 3. März.")
		// With a year the engine digits stay as written.
		XCTAssertEqual(one("Am 3 März 2026 Punkt"), "Am 3 März 2026.")
		XCTAssertEqual(one("Der Ein Schrägstrich Ausschalter funktioniert Punkt"), "Der Ein/Ausschalter funktioniert.")
	}

	func testInlineBullets() {
		XCTAssertEqual(one("Aufgaben Doppelpunkt Spiegelstrich Bericht schreiben Spiegelstrich Unterlagen scannen"),
		               "Aufgaben:\n- Bericht schreiben\n- Unterlagen scannen")
	}

	func testSplitStructuralPhraseIsJoined() {
		let result = run([
			("Anna fragte Fragezeichen Neuer", Int.max, 300, nil),
			("Absatz Ergebnis Doppelpunkt gut", 300, Int.max, nil),
		], tuning: .whisper)
		XCTAssertEqual(result, "Anna fragte?\n\nErgebnis: gut")
	}

	// MARK: Self-correction, numbers

	func testStrongSelfCorrectionSignal() {
		XCTAssertEqual(one("Die Kontrolle ist um vierzehn Uhr nein ich meine um fünfzehn Uhr Punkt"), "Die Kontrolle ist um 15 Uhr.")
	}

	func testDatesMoneyAndDecimals() {
		XCTAssertEqual(one("Protokoll vom dritten März Doppelpunkt"), "Protokoll vom 3. März:")
		XCTAssertEqual(one("Die Kosten liegen bei tausendzweihundertfünfzig Euro Punkt"), "Die Kosten liegen bei 1.250 €.")
		XCTAssertEqual(one("Die Dosis bleibt bei 2 5 Milligramm Punkt"), "Die Dosis bleibt bei 2,5 mg.")
		XCTAssertEqual(one("Die Kosten liegen bei 1250 Euro Punkt"), "Die Kosten liegen bei 1.250 €.")
		// Years stay without separator.
		XCTAssertEqual(one("Im Jahr 2026 Punkt"), "Im Jahr 2026.")
		XCTAssertEqual(one("Protokoll vom dritten März", tuning: nil), "Protokoll vom 03.03.")
	}

	// MARK: Cleanup

	func testCleanupRemovesHallucinations() {
		XCTAssertEqual(run([("Erster Abschnitt Doppelpunkt Alpha", Int.max, 800, nil), ("嗯。", 800, 800, nil), ("Ende Punkt 嗯。", 800, Int.max, nil)],
		                   tuning: .qwen), "Erster Abschnitt: Alpha Ende.")
		XCTAssertEqual(one("Mir gefallen Rot und Gelb Ausrufezeichen you"), "Mir gefallen Rot und Gelb!")
		XCTAssertEqual(one("Ende Punkt Thank you"), "Ende.")
		XCTAssertEqual(one("I told you so Punkt"), "I told you so.")
	}

	func testGeneralProfileForOtherEngines() {
		let general = LiteralTuning.general
		XCTAssertFalse(general.gapFill)
		XCTAssertFalse(general.structuralWithoutTimings)
		XCTAssertNil(general.decodeSegmentPauseMs)
		// Same command, number and cleanup rules as the engine profiles.
		XCTAssertEqual(one("Bitte bring Kleber mit Punkt Danke Punkt", tuning: general), "Bitte bring Kleber mit. Danke.")
		XCTAssertEqual(one("Projektnotiz Doppelpunkt Neuer Absatz Der Patient Punkt", tuning: general), "Projektnotiz:\n\nDer Patient.")
		XCTAssertEqual(one("Aufgaben Doppelpunkt Spiegelstrich Bericht schreiben", tuning: general), "Aufgaben:\n- Bericht schreiben")
		XCTAssertEqual(one("Die Kosten liegen bei 1250 Euro Punkt", tuning: general), "Die Kosten liegen bei 1.250 €.")
		// Without word timings a structural command inside an utterance needs the mark before it.
		XCTAssertEqual(one("Das ist ein neuer Absatz im Text Punkt", tuning: general), "Das ist ein neuer Absatz im Text.")
	}

	func testNormalModeIgnoresTuning() {
		XCTAssertEqual(run([("Kleber mit Punkt you", Int.max, Int.max, nil)], tuning: .whisper, mode: .normal), "Kleber mit Punkt you")
	}

	// MARK: Whisper gap fill

	private let rate = 16_000
	private func tone(_ ms: Int) -> [Float] { (0..<(ms * rate / 1_000)).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / Float(rate)) } }
	private func silence(_ ms: Int) -> [Float] { Array(repeating: 0, count: ms * rate / 1_000) }

	func testGapFillRecoversSkippedSpeech() async throws {
		// Speech 0.5–2.0 s and 3.0–4.5 s; the first pass only heard the first part.
		let samples = silence(500) + tone(1_500) + silence(1_000) + tone(1_500) + silence(500)
		let first = EngineResult(text: "eins zwei", words: [EngineWord(text: "eins", start: 0.6, end: 1.2), EngineWord(text: "zwei", start: 1.3, end: 1.9)])
		let filled = try await WhisperGapFiller.fill(first, samples: samples) { part in
			// The re-decode hears one word in the middle of each tone in the chunk.
			let seconds = Double(part.count) / 16_000
			return EngineResult(text: "drei", words: [EngineWord(text: "drei", start: seconds / 2 - 0.2, end: seconds / 2 + 0.2)])
		}
		XCTAssertEqual(filled.words.map(\.text), ["eins", "zwei", "drei"])
	}

	func testGapFillTriesNoiseOnlyOnce() async throws {
		// A noise burst after the speech: the re-decode hears nothing, so the
		// later passes must not decode it again.
		let samples = silence(500) + tone(1_500) + silence(1_000) + tone(600) + silence(500)
		let first = EngineResult(text: "eins zwei", words: [EngineWord(text: "eins", start: 0.6, end: 1.2), EngineWord(text: "zwei", start: 1.3, end: 1.9)])
		let calls = Counter()
		let filled = try await WhisperGapFiller.fill(first, samples: samples) { _ in
			await calls.increment()
			return EngineResult(text: "")
		}
		XCTAssertEqual(filled, first)
		let count = await calls.value
		XCTAssertEqual(count, 1)
	}

	func testGapFillRetriesAnEmptyGroupInSmallerPieces() async throws {
		// Two speech parts close together form one group in the first pass. The group
		// decode hears nothing (Whisper skipped it), the single-utterance pass finds the words.
		let samples = silence(500) + tone(1_500) + silence(1_000) + tone(1_500) + silence(600) + tone(1_500) + silence(500)
		let first = EngineResult(text: "eins", words: [EngineWord(text: "eins", start: 0.6, end: 1.9)])
		let calls = Counter()
		let filled = try await WhisperGapFiller.fill(first, samples: samples) { part in
			await calls.increment()
			let seconds = Double(part.count) / 16_000
			// Only a single utterance (≤ 2 s, no padding) is transcribed.
			guard seconds <= 2 else { return EngineResult(text: "") }
			return EngineResult(text: "wort", words: [EngineWord(text: "wort", start: seconds / 2 - 0.2, end: seconds / 2 + 0.2)])
		}
		XCTAssertEqual(filled.words.map(\.text), ["eins", "wort", "wort"])
	}

	private actor Counter {
		var value = 0
		func increment() { value += 1 }
	}

	func testGapFillDropsDisplacedDuplicate() {
		let utterance = Utterance(id: 0, range: 16_000 ..< 32_000, pauseBeforeMs: Int.max, pauseAfterMs: Int.max)
		let words = [EngineWord(text: "Punkt", start: 1.5, end: 1.8), EngineWord(text: "Punkt", start: 9.5, end: 9.8)]
		let original: Set<String> = ["Punkt|9.5"]
		let kept = WhisperGapFiller.removingDisplacedDuplicates(words, original: original, utterances: [utterance], sampleRate: 16_000)
		XCTAssertEqual(kept.map(\.start), [1.5])
	}
}
