import XCTest
@testable import HexCore

/// Plan B4: „Normal + commands“ in batch mode, without double marks.
final class NormalCommandsTests: XCTestCase {
	private func normal(_ text: String, commands: Bool = true, language: String = "de") -> String {
		var options = DictationTextPipeline.Options(mode: .normal, language: language, formatNumbers: false, agentFormatting: false)
		options.spokenPunctuationInNormal = commands
		let tokens = DictationTextPipeline.process(text, options: options)
		return Assembler.render(tokens, options: AssemblerOptions(language: language, mode: .normal))
	}

	func testSpokenMarksBecomeMarks() {
		XCTAssertEqual(normal("Befund Doppelpunkt keine Blutung"), "Befund: keine Blutung")
		XCTAssertEqual(normal("Hallo Komma wie geht es Fragezeichen"), "Hallo, wie geht es?")
	}

	func testModelMarkAndSpokenMarkGiveOneMark() {
		XCTAssertEqual(normal("Das ist das Ende Punkt."), "Das ist das Ende.")
		XCTAssertEqual(normal("Hallo, Komma Welt."), "Hallo, Welt.")
		XCTAssertEqual(normal("Befund Doppelpunkt: keine Blutung."), "Befund: keine Blutung.")
		XCTAssertEqual(normal("Wirklich Fragezeichen?"), "Wirklich?")
	}

	func testWordsStayWords() {
		XCTAssertEqual(normal("Setz einen Punkt dahinter."), "Setz einen Punkt dahinter.")
		XCTAssertEqual(normal("Das Wort Komma steht hier."), "Das Wort Komma steht hier.")
	}

	func testOffByDefault() {
		XCTAssertEqual(normal("Befund Doppelpunkt keine Blutung.", commands: false), "Befund Doppelpunkt keine Blutung.")
		XCTAssertFalse(DictationSessionOptions(mode: .normal).spokenPunctuationInNormal)
	}
}
