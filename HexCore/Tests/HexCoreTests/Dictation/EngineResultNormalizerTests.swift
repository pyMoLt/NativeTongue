import XCTest
@testable import HexCore

final class EngineResultNormalizerTests: XCTestCase {
	func testLiteralStripsAutomaticMarksButKeepsSpokenCommands() {
		let raw = EngineResult(
			text: "Zweiter Abschnitt, Klammer auf, Alpha, Bindestrich Beta, Klammer zu, Fragezeichen.",
			words: [EngineWord(text: "Abschnitt,", start: 0, end: 0.5), EngineWord(text: "Klammer", start: 0.5, end: 1)],
			detectedLanguage: "de"
		)
		let clean = EngineResultNormalizer.apply(raw, punctuation: .suppressed)
		XCTAssertEqual(clean.text, "Zweiter Abschnitt Klammer auf Alpha Bindestrich Beta Klammer zu Fragezeichen")
		XCTAssertEqual(clean.words.map(\.text), ["Abschnitt", "Klammer"])
		XCTAssertEqual(clean.detectedLanguage, "de")
		XCTAssertTrue(clean.punctuationWasSuppressed)
	}

	func testNormalizedNonWhisperStyleOutputStillFeedsLiteralCommandGrammar() {
		let parakeetStyle = EngineResult(text: "Zweiter Abschnitt, Klammer auf, Alpha, Bindestrich Beta, Klammer zu, Fragezeichen.")
		let clean = EngineResultNormalizer.apply(parakeetStyle, punctuation: .suppressed)
		let classification = UtteranceClassifier.classify(
			text: clean.text,
			pauseBeforeMs: Int.max,
			pauseAfterMs: Int.max,
			context: ClassifierContext(mode: .literal)
		)
		var document = DictationDocument()
		document.append(
			utteranceID: 0,
			tokens: DictationTextPipeline.tokens(
				for: classification,
				options: .init(mode: .literal, language: "de")
			)
		)
		XCTAssertEqual(document.render(.init(language: "de", mode: .literal)), "Zweiter Abschnitt (Alpha-Beta)?")
	}

	func testLiteralPreservesMeaningfulInternalMarks() {
		let raw = EngineResult(text: "Patient mit ST-Hebungsinfarkt, z.B. 2,5 mg Punkt")
		let clean = EngineResultNormalizer.apply(raw, punctuation: .suppressed)
		XCTAssertEqual(clean.text, "Patient mit ST-Hebungsinfarkt z.B. 2,5 mg Punkt")
	}

	func testNormalLeavesEngineResultUntouched() {
		let raw = EngineResult(text: "Hallo, Welt.", words: [EngineWord(text: "Hallo,", start: 0, end: 0.3)])
		XCTAssertEqual(EngineResultNormalizer.apply(raw, punctuation: .natural), raw)
	}
}
