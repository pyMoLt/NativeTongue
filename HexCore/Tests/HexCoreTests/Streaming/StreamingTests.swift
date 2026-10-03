import XCTest
@testable import HexCore

final class StreamingTextJoinerTests: XCTestCase {
	func testEmptyFieldCapitalizesWithoutSpace() {
		XCTAssertEqual(StreamingTextJoiner.join(" hallo welt", after: nil, adapt: true), "Hallo welt")
		XCTAssertEqual(StreamingTextJoiner.join("hallo", after: "", adapt: true), "Hallo")
	}

	func testContinuesWordWithSpace() {
		XCTAssertEqual(StreamingTextJoiner.join("welt", after: "Hallo", adapt: true), " welt")
		XCTAssertEqual(StreamingTextJoiner.join(" welt", after: "Hallo ", adapt: true), "welt")
	}

	func testCapitalizesAfterTypedSentenceEnd() {
		XCTAssertEqual(StreamingTextJoiner.join("und weiter", after: "Erster Satz.", adapt: true), " Und weiter")
		XCTAssertEqual(StreamingTextJoiner.join("neuer absatz", after: "Ende\n", adapt: true), "Neuer absatz")
	}

	func testUserTypedCommaKeepsLowercase() {
		XCTAssertEqual(StreamingTextJoiner.join("dann", after: "Hallo,", adapt: true), " dann")
	}

	func testPunctuationAttachesWithoutSpace() {
		XCTAssertEqual(StreamingTextJoiner.join(". Weiter", after: "Satz", adapt: true), ". Weiter")
	}

	func testNoAdaptationKeepsPiece() {
		XCTAssertEqual(StreamingTextJoiner.join(" welt", after: "Hallo.", adapt: false), " welt")
	}
}

final class StreamingPauseDetectorTests: XCTestCase {
	private func tone(_ seconds: Double) -> [Float] {
		(0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.2)) * 0.2 }
	}

	private func silence(_ seconds: Double) -> [Float] {
		Array(repeating: 0, count: Int(seconds * 16_000))
	}

	func testCutsBlockAfterPause() {
		var detector = StreamingPauseDetector(pauseMs: 500)
		XCTAssertTrue(detector.append(tone(1)).isEmpty)
		let blocks = detector.append(silence(0.6))
		XCTAssertEqual(blocks.count, 1)
		XCTAssertGreaterThanOrEqual(blocks[0].count, 16_000)
	}

	func testSilenceAloneProducesNothing() {
		var detector = StreamingPauseDetector()
		XCTAssertTrue(detector.append(silence(3)).isEmpty)
		XCTAssertNil(detector.flush())
		XCTAssertGreaterThan(detector.silenceSeconds, 2.9)
	}

	func testLongSpeechIsCutAtMaxBlock() {
		var detector = StreamingPauseDetector(maxBlockSeconds: 2)
		XCTAssertEqual(detector.append(tone(5)).count, 2)
		XCTAssertNotNil(detector.flush())
	}

	func testDecodesOldSettingsWithoutStreaming() throws {
		let settings = try JSONDecoder().decode(StreamingSettings.self, from: Data("{}".utf8))
		XCTAssertEqual(settings.nemotronChunkMs, 1120)
		XCTAssertEqual(settings.hotkeyBehavior, .toggle)
		XCTAssertFalse(settings.literalStreamingInBox)
	}
}

final class StreamingTextProcessorTests: XCTestCase {
	func testHoldsBackUnfinishedWord() {
		var processor = StreamingTextProcessor(options: .init())
		XCTAssertEqual(processor.push("Der Pati"), "Der")
		XCTAssertEqual(processor.push("ent kommt"), " Patient")
		XCTAssertEqual(processor.flush(), " kommt")
	}

	func testLineBreakCommandAcrossDeltas() {
		var processor = StreamingTextProcessor(options: .init(commands: .lineBreaksOnly))
		var typed = processor.push("Satz eins neuer")
		typed += processor.push(" Absatz Satz zwei ")
		typed += processor.flush()
		XCTAssertEqual(typed, "Satz eins\n\nSatz zwei ")
	}

	func testCommandsOffKeepsWords() {
		var processor = StreamingTextProcessor(options: .init(commands: .off))
		XCTAssertEqual(processor.push("neuer Absatz ") + processor.flush(), "neuer Absatz ")
	}

	func testAliasesAndPunctuation() {
		var processor = StreamingTextProcessor(options: .init(keepPunctuation: false, aliases: ["gwen": "Qwen"]))
		XCTAssertEqual(processor.push("Wir nutzen Gwen, oder? ") + processor.flush(), "Wir nutzen Qwen oder ")
	}

	func testMultiwordAliasAcrossDeltasAndPause() {
		var processor = StreamingTextProcessor(options: .init(aliases: ["vox drill": "Voxtral", "nervus vagus": "Nervus vagus"]))
		XCTAssertEqual(processor.push("Nutze Vox "), "Nutze")
		XCTAssertNil(processor.releaseHeldWord())
		XCTAssertEqual(processor.push("Drill, dann Ner"), " Voxtral, dann")
		XCTAssertEqual(processor.push("vus Vagus ") + processor.flush(), " Nervus vagus ")
	}

	func testAliasPrefixFallsBackWhenNextWordDoesNotMatch() {
		var processor = StreamingTextProcessor(options: .init(aliases: ["vox drill": "Voxtral"]))
		XCTAssertEqual(processor.push("Vox "), "")
		XCTAssertNil(processor.releaseHeldWord())
		XCTAssertEqual(processor.push("anders ") + processor.flush(), "Vox anders ")
	}
}

final class StreamingPauseReleaseTests: XCTestCase {
	func testHeldWordIsReleasedInPause() {
		var processor = StreamingTextProcessor(options: .init())
		XCTAssertEqual(processor.push("Hallo Welt"), "Hallo")
		XCTAssertEqual(processor.releaseHeldWord(), " Welt")
		XCTAssertNil(processor.releaseHeldWord())
	}

	func testCommandStartIsKeptInPause() {
		var processor = StreamingTextProcessor(options: .init(commands: .lineBreaksOnly))
		_ = processor.push("Satz neuer")
		XCTAssertNil(processor.releaseHeldWord())
	}
}


/// Spoken punctuation, numbers and values while streaming (no pauses needed).
final class StreamingFormattingTests: XCTestCase {
	private func stream(_ deltas: [String], _ options: StreamingTextProcessor.Options) -> String {
		var processor = StreamingTextProcessor(options: options)
		var typed = ""
		for delta in deltas { typed += processor.push(delta) }
		return (typed + processor.flush()).trimmingCharacters(in: .whitespaces)
	}

	private let literal = StreamingTextProcessor.Options(keepPunctuation: false, commands: .all, formatNumbers: true)

	func testSpokenPunctuationLiteral() {
		let deltas = ["Hallo", " Komma", " wie", " geht", " es", " dir", " Fragezeichen", " gut", " Punkt"]
		XCTAssertEqual(stream(deltas, literal), "Hallo, wie geht es dir? Gut.")
	}

	func testBracketsColonAndQuotes() {
		let deltas = [" Befund", " Doppelpunkt", " unauffällig", " Klammer", " auf", " siehe", " oben", " Klammer", " zu", " Punkt"]
		XCTAssertEqual(stream(deltas, literal), "Befund: unauffällig (siehe oben).")
	}

	func testNumbersAndUnitsAcrossDeltas() {
		let deltas = [" Der", " Patient", " bekommt", " zwei", " Komma", " fünf", " Milli", "gramm", " Rivaroxaban", " Punkt"]
		XCTAssertEqual(stream(deltas, literal), "Der Patient bekommt 2,5 mg Rivaroxaban.")
	}

	func testParagraphCommandAtChunkStart() {
		let deltas = ["Satz", " eins", " Punkt", " neuer", " Absatz", " zweiter", " Satz", " Punkt"]
		XCTAssertEqual(stream(deltas, literal), "Satz eins.\n\nZweiter Satz.")
	}

	func testAutomaticModeKeepsModelPunctuationAndLeavesCommandsAlone() {
		let options = StreamingTextProcessor.Options(keepPunctuation: true, commands: .off, formatNumbers: false)
		XCTAssertEqual(stream(["Hallo,", " wie", " geht's?", " Komma"], options), "Hallo, wie geht's? Komma")
	}

	func testCombinedModeAddsSpokenCommandsToModelPunctuation() {
		let options = StreamingTextProcessor.Options(keepPunctuation: true, commands: .all, formatNumbers: true)
		XCTAssertEqual(stream(["Werte:", " Klammer", " auf", " zwölf", " Prozent", " Klammer", " zu."], options), "Werte: (12 %).")
	}

	func testCombinedModeDropsSpeculativePeriodBeforeSpokenOpenBracket() {
		let options = StreamingTextProcessor.Options(keepPunctuation: true, commands: .all)
		XCTAssertEqual(stream(["Zweiter Abschnitt.", " Klammer", " auf", " Alpha", " Klammer", " zu"], options),
			"Zweiter Abschnitt (Alpha)")
	}

	func testPauseReleasesHeldNumber() {
		var processor = StreamingTextProcessor(options: literal)
		XCTAssertEqual(processor.push("Dosis zwanzig "), "Dosis")
		XCTAssertEqual(processor.releaseHeldWord(), " 20")
	}

	func testCombinedModeDropsEchoedModelMarks() {
		let options = StreamingTextProcessor.Options(keepPunctuation: true, commands: .all, formatNumbers: true)
		XCTAssertEqual(stream(["Alpha,", " Komma,", " Beta", " Fragezeichen."], options), "Alpha, Beta?")
	}

	func testBasicLiteralScopeIgnoresBrackets() {
		var settings = StreamingSettings()
		settings.punctuationMode = .literal
		settings.literalScope = .basic
		let options = StreamingTextProcessor.Options(settings: settings, language: "de", englishCommands: true, aliases: [:])
		XCTAssertEqual(stream(["Test", " Klammer", " auf", " Alpha", " Komma", " Beta", " Punkt"], options), "Test Klammer auf Alpha, Beta.")
	}

	func testHyphenAttachesAcrossChunks() {
		XCTAssertEqual(stream(["Alpha", " Bindestrich", " Beta"], literal), "Alpha-Beta")
	}

	func testCombinedModeDropsEchoAcrossChunks() {
		let options = StreamingTextProcessor.Options(keepPunctuation: true, commands: .all, formatNumbers: true)
		XCTAssertEqual(stream(["Satz.", " Neuer", " Absatz.", " Erster", " Abschnitt", " Ende,", " Punkt."], options), "Satz.\n\nErster Abschnitt Ende.")
	}
}
