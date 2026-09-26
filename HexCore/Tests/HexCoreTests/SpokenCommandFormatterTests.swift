import XCTest
@testable import HexCore

final class SpokenCommandFormatterTests: XCTestCase {
	func testNormalModeOnlyFormatsExplicitLineAndParagraphCommands() {
		let input = "Bitte neue Zeile danach neuer Absatz fertig"
		let timings = [
			word("Bitte", 0.00, 0.25),
			word("neue", 0.80, 1.02),
			word("Zeile", 1.05, 1.25),
			word("danach", 1.90, 2.15),
			word("neuer", 2.90, 3.10),
			word("Absatz", 3.12, 3.28),
			word("fertig", 3.90, 4.10)
		]
		let output = SpokenCommandFormatter.apply(input, mode: .normal, wordTimings: timings)

		XCTAssertEqual(output, "Bitte\ndanach\n\nfertig")
	}

	func testNormalModeLeavesLinePhrasesInlineWithoutPause() {
		let input = "Bitte neue Zeile anlegen"
		let timings = [
			word("Bitte", 0.00, 0.20),
			word("neue", 0.24, 0.45),
			word("Zeile", 0.49, 0.70),
			word("anlegen", 0.74, 1.00)
		]

		XCTAssertEqual(SpokenCommandFormatter.apply(input, mode: .normal, wordTimings: timings), input)
	}

	func testNormalModeRequiresUnambiguousTimingAlignment() {
		let input = "Bitte neue Zeile"
		let timings = [word("Bitte", 0, 0.2), word("neue", 0.8, 1.0)]

		XCTAssertEqual(SpokenCommandFormatter.apply(input, mode: .normal, wordTimings: timings), input)
	}

	func testNormalModeIgnoresStandalonePunctuationWhenAligningCommandTimings() {
		let input = "Voran , neuer Absatz , danach"
		let timings = [
			word("Voran", 0.00, 0.20),
			word("neuer", 0.90, 1.10),
			word("Absatz", 1.13, 1.35),
			word("danach", 2.10, 2.30),
		]

		XCTAssertEqual(
			SpokenCommandFormatter.apply(input, mode: .normal, wordTimings: timings),
			"Voran\n\ndanach"
		)
	}

	func testStructuralCommandCanUsePauseAfterPhraseOnly() {
		let input = "Start neuer Absatz weiter"
		let timings = [
			word("Start", 0.00, 0.20),
			word("neuer", 0.25, 0.45),
			word("Absatz", 0.48, 0.68),
			word("weiter", 1.30, 1.50),
		]

		XCTAssertEqual(
			SpokenCommandFormatter.apply(input, mode: .normal, wordTimings: timings),
			"Start\n\nweiter"
		)
	}

	func testStructuralCommandCanUsePauseBeforePhraseOnly() {
		let input = "Start neuer Absatz weiter"
		let timings = [
			word("Start", 0.00, 0.20),
			word("neuer", 1.00, 1.20),
			word("Absatz", 1.23, 1.43),
			word("weiter", 1.47, 1.70),
		]

		XCTAssertEqual(
			SpokenCommandFormatter.apply(input, mode: .normal, wordTimings: timings),
			"Start\n\nweiter"
		)
	}

	func testStructuralCommandDoesNotTreatTranscriptEdgeAsPause() {
		let input = "neuer Absatz weiter"
		let timings = [
			word("neuer", 0.00, 0.20),
			word("Absatz", 0.23, 0.43),
			word("weiter", 0.47, 0.67),
		]

		XCTAssertEqual(SpokenCommandFormatter.apply(input, mode: .normal, wordTimings: timings), input)
	}

	func testNormalModeLeavesPunctuationWordsAlone() {
		let input = "Komma ist ein Satzzeichen und Klammer auf ist ein Befehl"

		XCTAssertEqual(SpokenCommandFormatter.apply(input, mode: .normal), input)
	}

	func testLiteralModeFormatsGermanAndEnglishPunctuationCommands() {
		let german = SpokenCommandFormatter.apply(
			"Hallo Komma Welt Punkt neue Zeile nächster Satz Doppelpunkt eins",
			mode: .literal,
			wordTimings: [
				word("Hallo", 0.00, 0.20), word("Komma", 0.24, 0.44),
				word("Welt", 0.48, 0.68), word("Punkt", 0.72, 0.92),
				word("neue", 1.50, 1.70), word("Zeile", 1.74, 1.94),
				word("nächster", 2.52, 2.72), word("Satz", 2.76, 2.96),
				word("Doppelpunkt", 3.00, 3.20), word("eins", 3.24, 3.44),
			]
		)
		let english = SpokenCommandFormatter.apply(
			"Hello comma world period new paragraph next line",
			mode: .literal,
			wordTimings: [
				word("Hello", 0.00, 0.20), word("comma", 0.24, 0.44),
				word("world", 0.48, 0.68), word("period", 0.72, 0.92),
				word("new", 1.50, 1.70), word("paragraph", 1.74, 1.94),
				word("next", 2.52, 2.72), word("line", 2.76, 2.96),
			]
		)

		XCTAssertEqual(german, "Hallo, Welt.\nnächster Satz: eins")
		XCTAssertEqual(english, "Hello, world.\n\nnext line")
	}

	func testLiteralPunctuationReplacesAdjacentASRCommasAroundCommand() {
		let inputs = [
			"Heading , Doppelpunkt , Details",
			"Heading, Doppelpunkt, Details",
			"Heading , Doppelpunkt, Details",
		]

		for input in inputs {
			XCTAssertEqual(
				SpokenCommandFormatter.apply(input, mode: .literal),
				"Heading: Details",
				"Input: \(input)"
			)
		}
	}

	func testLiteralModeRequiresPauseTimingsForStructuralCommandsOnly() {
		let input = "Hallo Komma neue Zeile weiter"

		XCTAssertEqual(
			SpokenCommandFormatter.apply(input, mode: .literal),
			"Hallo, neue Zeile weiter"
		)
	}

	func testLiteralModePairsExplicitParenthesisAndHyphenCommands() {
		let input = "Musculus Klammer auf Vastus lateralis Klammer zu Bindestrich links"

		XCTAssertEqual(SpokenCommandFormatter.apply(input, mode: .literal), "Musculus (Vastus lateralis)-links")
	}

	func testLiteralModeCoversRemainingQuoteBracketAndTechnicalSymbols() {
		let cases = [
			("A Semikolon B", "A; B"),
			("A Fragezeichen B", "A? B"),
			("A Ausrufezeichen B", "A! B"),
			("A eckige Klammer auf x eckige Klammer zu B", "A [x] B"),
			("A geschweifte Klammer auf x geschweifte Klammer zu B", "A {x} B"),
			("A Anführungszeichen auf x Anführungszeichen zu B", "A “x” B"),
			("A Schrägstrich B", "A/B"),
			("A Backslash B", "A\\B"),
			("A Unterstrich B", "A_B"),
			("A at Zeichen B", "A@B"),
			("A Gedankenstrich B", "A — B"),
		]

		for (input, expected) in cases {
			XCTAssertEqual(SpokenCommandFormatter.apply(input, mode: .literal), expected, "Input: \(input)")
		}
	}

	func testNaturalWordsInsideLargerWordsAreNotCommands() {
		let input = "The commaSeparated value has a periodontist nearby"

		XCTAssertEqual(SpokenCommandFormatter.apply(input, mode: .literal), input)
	}

	func testExistingSpacingIsNormalizedOnlyAroundExplicitCommands() {
		let input = "Text    Komma   danach Klammer auf   Inhalt   Klammer zu"

		XCTAssertEqual(SpokenCommandFormatter.apply(input, mode: .literal), "Text, danach (Inhalt)")
	}

	private func word(_ word: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptWordTiming {
		TranscriptWordTiming(word: word, startTime: start, endTime: end)
	}
}
