import XCTest
@testable import HexCore

final class SpelledWordRendererTests: XCTestCase {
	private func render(_ text: String, mode: DictationMode = .normal) -> String {
		let tokens = DictationTextPipeline.process(text, options: .init(mode: mode, language: "de", formatNumbers: false, agentFormatting: false))
		return Assembler.render(tokens, options: AssemblerOptions(language: "de", mode: mode))
	}

	func testWriteCapitalLetters() {
		XCTAssertEqual(render("der Code lautet bitte schreibe groß a b c und dann weiter"), "der Code lautet ABC und dann weiter")
	}

	func testAlphabetPairs() {
		XCTAssertEqual(render("der Wirkstoff heißt a wie Anton p wie Paula i wie Ida x wie Xanthippe"), "der Wirkstoff heißt APIX")
	}

	func testAlphabetPairsWithModelCommas() {
		XCTAssertEqual(render("Kürzel: A wie Anton, B wie Berta, C wie Cäsar."), "Kürzel: ABC.")
	}

	func testSpellCommandWithAlphabetWords() {
		XCTAssertEqual(render("buchstabiere Nordpol Otto Richard Dora"), "NORD")
	}

	func testOrdinaryTextStays() {
		XCTAssertEqual(render("I have a dog and a cat"), "I have a dog and a cat")
		XCTAssertEqual(render("so wie Anton es sagt"), "so wie Anton es sagt")
		XCTAssertEqual(render("schreibe groß und deutlich"), "schreibe groß und deutlich")
	}

	func testLiteralModeToo() {
		XCTAssertEqual(render("Code schreibe groß x y z Punkt", mode: .literal), "Code XYZ.")
	}
}
