import XCTest
@testable import HexCore

final class RepetitionLoopTests: XCTestCase {
	func testCollapsesPhraseLoop() {
		let looped = "Der Befund ist unauffällig und dann und dann und dann und dann und dann"
		XCTAssertEqual(HallucinationFilter.collapsingRepetitionLoops(looped), "Der Befund ist unauffällig und dann")
	}

	func testCollapsesSingleWordLoop() {
		XCTAssertEqual(HallucinationFilter.collapsingRepetitionLoops("okay okay okay okay okay okay weiter"), "okay weiter")
	}

	func testIgnoresPunctuationAndCaseWhileMatching() {
		let looped = "Thank you. Thank you. thank you, Thank you. Done"
		XCTAssertEqual(HallucinationFilter.collapsingRepetitionLoops(looped), "Thank you. Done")
	}

	func testKeepsOrdinaryEmphasis() {
		let text = "Das ist sehr, sehr, sehr wichtig und wirklich wirklich gut"
		XCTAssertEqual(HallucinationFilter.collapsingRepetitionLoops(text), text)
	}

	func testKeepsThreeRepeatsOfAPhrase() {
		let text = "eins zwei eins zwei eins zwei drei"
		XCTAssertEqual(HallucinationFilter.collapsingRepetitionLoops(text), text)
	}

	func testSessionProcessorCollapsesLoopsBeforeCommands() {
		let utterance = Utterance(id: 0, range: 0..<32_000, pauseBeforeMs: 0, pauseAfterMs: 0)
		let aligned = [AlignedUtterance(utterance: utterance, text: "Hallo Welt Welt Welt Welt Welt Welt")]
		let document = DictationSessionProcessor.makeDocument(from: aligned, options: .init(mode: .normal, formatNumbers: false))
		XCTAssertFalse(document.render(.init(language: "de", mode: .normal)).contains("Welt Welt"))
	}
}
