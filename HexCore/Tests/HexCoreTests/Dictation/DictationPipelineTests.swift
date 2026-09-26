import XCTest
@testable import HexCore

final class DictationPipelineTests: XCTestCase {
	private let literal = ClassifierContext(mode: .literal)
	private let normal = ClassifierContext(mode: .normal)

	/// Feeds utterances (text, pause before, pause after) through classifier → document.
	private func run(_ utterances: [(String, Int, Int)], context: ClassifierContext, language: String = "de", format: OutputFormat = .plainText) -> String {
		var document = DictationDocument()
		let options = DictationTextPipeline.Options(mode: context.mode, language: language)
		for (id, (text, before, after)) in utterances.enumerated() {
			let cls = UtteranceClassifier.classify(text: text, pauseBeforeMs: before, pauseAfterMs: after, context: context)
			if case let .command(.edit(edit)) = cls {
				document.apply(edit)
			} else {
				document.append(utteranceID: id, tokens: DictationTextPipeline.tokens(for: cls, options: options))
			}
		}
		return document.render(AssemblerOptions(language: language, mode: context.mode, format: format))
	}

	// MARK: Acceptance (plan 5.4)

	/// Whisper Turbo + punctuation suppression output of the user's literal recording,
	/// split at the measured pauses (see benchmark results).
	func testLiteralRecordingProducesExpectedDocument() {
		let utterances: [(String, Int, Int)] = [
			("Dies ist ein kurzer Test für Satzzeichen und Absätze Punkt", Int.max, 1_700),
			("Neuer Absatz", 1_700, 1_300),
			("Erster Abschnitt Doppelpunkt Alpha Komma Beta Punkt", 1_300, 1_260),
			("Neue Zeile", 1_260, 620),
			("Zweiter Abschnitt Klammer auf Alpha Bindestrich Beta Klammer zu Fragezeichen", 620, 480),
			("Neuer Absatz", 480, 1_160),
			("Dritter Abschnitt Semikolon Abschluss Komma Ende Punkt", 1_160, Int.max),
		]
		XCTAssertEqual(run(utterances, context: literal), """
		Dies ist ein kurzer Test für Satzzeichen und Absätze.

		Erster Abschnitt: Alpha, Beta.
		Zweiter Abschnitt (Alpha-Beta)?

		Dritter Abschnitt; Abschluss, Ende.
		""")
	}

	func testLiteralStripsModelPunctuationAroundSpokenCommands() {
		// Parakeet-style output with its own commas around command words.
		let text = run([("Zweiter Abschnitt, Klammer auf, Alpha, Bindestrich Beta, Klammer zu, Fragezeichen.", Int.max, Int.max)], context: literal)
		XCTAssertEqual(text, "Zweiter Abschnitt (Alpha-Beta)?")
	}

	func testLiteralKeepsDecimalsAbbreviationsAndCompounds() {
		let text = run([("Patient mit ST-Hebungsinfarkt, z.B. 2,5 mg Punkt", Int.max, Int.max)], context: literal)
		XCTAssertEqual(text, "Patient mit ST-Hebungsinfarkt z.B. 2,5 mg.")
	}

	func testLiteralQuotesFollowLanguage() {
		XCTAssertEqual(run([("er sagte Anführungszeichen auf Hallo Anführungszeichen zu Punkt", Int.max, Int.max)], context: literal), "Er sagte „Hallo“.")
		XCTAssertEqual(run([("he said open quote hello close quote period", Int.max, Int.max)], context: literal, language: "en"), "He said “hello”.")
	}

	func testLiteralEnglishPunctuationWordsFromGermanModelOutput() {
		// Cohere/others sometimes write "comma" in German dictation.
		XCTAssertEqual(run([("Alpha comma Beta Punkt", Int.max, Int.max)], context: literal), "Alpha, Beta.")
	}

	// MARK: Structural commands and pauses

	func testNormalModeParagraphNeedsIsolation() {
		let inline = run([("Der Ausdruck neuer Absatz ist nur ein Beispiel.", Int.max, Int.max)], context: normal)
		XCTAssertEqual(inline, "Der Ausdruck neuer Absatz ist nur ein Beispiel.")
		let isolated = run([
			("Das ist Satz eins.", Int.max, 800),
			("Neuer Absatz.", 800, 800),
			("Satz zwei.", 800, Int.max),
		], context: normal)
		XCTAssertEqual(isolated, "Das ist Satz eins.\n\nSatz zwei.")
	}

	func testShortPauseDoesNotTriggerStructuralCommand() {
		let text = run([("Das ist Satz eins.", Int.max, 200), ("Neue Zeile", 200, 200), ("Weiter.", 200, Int.max)], context: normal)
		XCTAssertEqual(text, "Das ist Satz eins. Neue Zeile Weiter.")
	}

	func testEdgeCommandWithPauseOnThatSide() {
		let cls = UtteranceClassifier.classify(text: "Ende des Befundes. Neuer Absatz.", pauseBeforeMs: 300, pauseAfterMs: 900, context: normal)
		XCTAssertEqual(cls, .dictation(leading: nil, text: "Ende des Befundes.", trailing: .newParagraph))
		let noPause = UtteranceClassifier.classify(text: "Ende des Befundes. Neuer Absatz.", pauseBeforeMs: 300, pauseAfterMs: 0, context: normal)
		XCTAssertEqual(noPause, .dictation(leading: nil, text: "Ende des Befundes. Neuer Absatz.", trailing: nil))
		let leading = UtteranceClassifier.classify(text: "Neue Zeile, zweiter Abschnitt", pauseBeforeMs: 900, pauseAfterMs: 0, context: literal)
		XCTAssertEqual(leading, .dictation(leading: .newLine, text: "zweiter Abschnitt", trailing: nil))
	}

	func testAbsatzAloneOnlyWhenIsolated() {
		XCTAssertEqual(UtteranceClassifier.classify(text: "Absatz", pauseBeforeMs: 900, pauseAfterMs: 900, context: normal), .command(.structural(.newParagraph)))
		XCTAssertEqual(UtteranceClassifier.classify(text: "Absatz drei regelt das", pauseBeforeMs: 900, pauseAfterMs: 900, context: normal),
		               .dictation(leading: nil, text: "Absatz drei regelt das", trailing: nil))
	}

	func testCapitalizationAfterBreaks() {
		let text = run([("erster Satz", Int.max, 900), ("Neue Zeile", 900, 900), ("zweiter Satz", 900, Int.max)], context: literal)
		XCTAssertEqual(text, "Erster Satz\nZweiter Satz")
	}

	// MARK: Edit commands

	func testScratchThatRemovesLastUtterance() {
		let text = run([("Satz eins.", Int.max, 800), ("Satz zwei.", 800, 800), ("streich das", 800, 800), ("Satz drei.", 800, Int.max)], context: normal)
		XCTAssertEqual(text, "Satz eins. Satz drei.")
	}

	func testDeleteLastSentenceAndWordAndUndo() {
		XCTAssertEqual(run([("Eins. Zwei drei.", Int.max, 800), ("streich den letzten Satz", 800, Int.max)], context: normal), "Eins.")
		XCTAssertEqual(run([("Eins zwei drei", Int.max, 800), ("lösche das letzte Wort", 800, Int.max)], context: normal), "Eins zwei")
		XCTAssertEqual(run([("Eins.", Int.max, 800), ("Zwei.", 800, 800), ("streich das", 800, 800), ("rückgängig", 800, Int.max)], context: normal), "Eins. Zwei.")
		XCTAssertEqual(run([("Eins.", Int.max, 800), ("scratch that", 800, Int.max)], context: normal), "")
	}

	func testEditCommandsNeedIsolation() {
		XCTAssertEqual(run([("Bitte streich das aus dem Plan.", Int.max, Int.max)], context: normal), "Bitte streich das aus dem Plan.")
	}

	// MARK: Format commands

	func testFormatCommandsInLiteral() {
		let markdown = run([
			("Überschrift Befund", Int.max, 800),
			("Spiegelstrich", 800, 800),
			("erster Punkt der Liste", 800, 800),
			("Spiegelstrich zweiter Eintrag", 800, 800),
			("das ist fett an wichtig fett aus", 800, Int.max),
		], context: literal, format: .markdown)
		XCTAssertEqual(markdown, "# Befund\n- Erster. Der Liste\n- Zweiter Eintrag das ist **wichtig**")
	}

	func testAllCapsAndLowercase() {
		XCTAssertEqual(run([("die Abkürzung alles groß who", Int.max, Int.max)], context: literal), "Die Abkürzung WHO")
	}

	// MARK: Hallucinations

	func testHallucinationFilter() {
		XCTAssertTrue(HallucinationFilter.shouldDrop(text: "Vielen Dank.", utteranceDurationMs: 900))
		XCTAssertFalse(HallucinationFilter.shouldDrop(text: "Vielen Dank.", utteranceDurationMs: 4_000))
		XCTAssertFalse(HallucinationFilter.shouldDrop(text: "Vielen Dank für den Befund.", utteranceDurationMs: 900))
	}
}
