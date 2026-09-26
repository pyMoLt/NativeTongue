import XCTest
@testable import HexCore

final class SpellingInterpreterTests: XCTestCase {
	func testGermanAlphabetProducesUppercaseWord() {
		XCTAssertEqual(SpellingInterpreter.interpret("Anton Paula Ida Xanthippe Anton Berta Anton Nordpol"), "APIXABAN")
	}

	func testCaseDigitsAndSymbols() {
		XCTAssertEqual(SpellingInterpreter.interpret("groß Anton klein Paula klein Ida"), "Api")
		XCTAssertEqual(SpellingInterpreter.interpret("S T Bindestrich H"), "ST-H")
		XCTAssertEqual(SpellingInterpreter.interpret("Alpha Bravo drei"), "AB3")
		XCTAssertEqual(SpellingInterpreter.interpret("Ärger Ökonom Eszett"), "ÄÖß")
	}

	func testUnknownWordsAreIgnored() {
		XCTAssertEqual(SpellingInterpreter.interpret("äh Anton, Berta."), "AB")
	}
}

final class DictationBoxDocumentTests: XCTestCase {
	private func utterance(_ id: Int, _ text: String, before: Int = 900, after: Int = 900) -> AlignedUtterance {
		AlignedUtterance(utterance: Utterance(id: id, range: 0..<16_000, pauseBeforeMs: before, pauseAfterMs: after), text: text)
	}

	func testEditWithoutContentIsKeptForTheBox() {
		let document = DictationSessionProcessor.makeDocument(from: [utterance(0, "streich das")], options: .init(mode: .literal, boxOpen: true))
		XCTAssertTrue(document.isEmpty)
		XCTAssertEqual(document.unappliedEdits, [.deleteLastUtterance])
	}

	func testBoxCommandsOnlyWhenBoxIsOpen() {
		let open = DictationSessionProcessor.makeDocument(
			from: [utterance(0, "Befund unauffällig", after: 900), utterance(1, "Text übertragen")],
			options: .init(mode: .literal, formatNumbers: false, boxOpen: true)
		)
		XCTAssertEqual(open.boxCommands, [.transfer])
		XCTAssertEqual(open.render(.init(language: "de", mode: .literal)), "Befund unauffällig")
		let closed = DictationSessionProcessor.makeDocument(
			from: [utterance(0, "Text übertragen")],
			options: .init(mode: .literal, formatNumbers: false, boxOpen: false)
		)
		XCTAssertTrue(closed.boxCommands.isEmpty)
		XCTAssertEqual(closed.render(.init(language: "de", mode: .literal)), "Text übertragen")
	}
}
