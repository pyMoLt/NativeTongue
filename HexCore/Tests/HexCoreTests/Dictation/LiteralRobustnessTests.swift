import XCTest
@testable import HexCore

/// Plan B3: word vs. command in Literal, pauses from word timestamps, ASR spellings.
final class LiteralRobustnessTests: XCTestCase {
	private func literal(_ text: String, language: String = "de", gaps: [Int?]? = nil) -> String {
		let tokens = DictationTextPipeline.process(text, options: .init(mode: .literal, language: language, formatNumbers: false, wordGapsMs: gaps))
		return Assembler.render(tokens, options: AssemblerOptions(language: language, mode: .literal))
	}

	func testArticleOrPrepositionMakesItAWord() {
		XCTAssertEqual(literal("Setz einen Punkt dahinter"), "Setz einen Punkt dahinter")
		XCTAssertEqual(literal("Der Punkt ist wichtig"), "Der Punkt ist wichtig")
		XCTAssertEqual(literal("Das Komma fehlt"), "Das Komma fehlt")
		XCTAssertEqual(literal("Er steht im Doppelpunkt"), "Er steht im Doppelpunkt")
		XCTAssertEqual(literal("Wir treffen uns um Punkt zehn"), "Wir treffen uns um Punkt zehn")
		XCTAssertEqual(literal("Das Wort Punkt steht hier"), "Das Wort Punkt steht hier")
		XCTAssertEqual(literal("put a period here", language: "en"), "Put a period here")
		XCTAssertEqual(literal("the comma is missing", language: "en"), "The comma is missing")
	}

	func testStandaloneStaysACommand() {
		XCTAssertEqual(literal("Befund unauffällig Punkt"), "Befund unauffällig.")
		XCTAssertEqual(literal("Er sagte Doppelpunkt alles gut"), "Er sagte: alles gut")
		XCTAssertEqual(literal("Hallo Komma Welt"), "Hallo, Welt")
	}

	func testTimestampPauseOverridesTheArticleRule() {
		// „… den Befund [Pause] Doppelpunkt …“ vs. „… den Doppelpunkt …“
		XCTAssertEqual(literal("Siehe den Doppelpunkt hier", gaps: [nil, 40, 600, 60]), "Siehe den: hier")
		XCTAssertEqual(literal("Siehe den Doppelpunkt hier", gaps: [nil, 40, 80, 60]), "Siehe den Doppelpunkt hier")
	}

	func testAsrSpellingsOfCommands() {
		XCTAssertEqual(literal("Wirklich Frage Zeichen"), "Wirklich?")
		XCTAssertEqual(literal("Achtung Ausrufe Zeichen"), "Achtung!")
		XCTAssertEqual(literal("A Schräg Strich B"), "A/B")
		XCTAssertEqual(literal("Klammer-auf links Klammer-zu"), "(Links)")
		XCTAssertEqual(literal("Teil eins Semi Kolon Teil zwei"), "Teil eins; Teil zwei")
		XCTAssertEqual(literal("Binde Strich"), "-")
	}

	func testAlignmentCarriesGapsPerWord() throws {
		let words = [
			EngineWord(text: "Siehe", start: 0.0, end: 0.3),
			EngineWord(text: " den", start: 0.35, end: 0.5),
			EngineWord(text: " Doppelpunkt", start: 1.2, end: 1.6),
		]
		let utterance = Utterance(id: 0, range: 0..<32_000, pauseBeforeMs: 900, pauseAfterMs: 900)
		let aligned = try XCTUnwrap(DictationSessionProcessor.align(EngineResult(text: "", words: words), to: [utterance]))
		XCTAssertEqual(aligned[0].wordGapsMs, [nil, 50, 700])
		let document = DictationSessionProcessor.makeDocument(from: aligned, options: .init(mode: .literal, formatNumbers: false))
		XCTAssertEqual(document.render(.init(language: "de", mode: .literal)), "Siehe den:")
	}
}
