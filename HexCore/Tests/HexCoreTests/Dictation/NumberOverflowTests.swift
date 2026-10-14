import XCTest
@testable import HexCore

/// Long spoken number sequences must never crash (audit M1: integer overflow trapped).
final class NumberOverflowTests: XCTestCase {
	private func render(_ text: String, mode: DictationMode, language: String = "de") -> String {
		let tokens = DictationTextPipeline.process(text, options: .init(mode: mode, language: language))
		return Assembler.render(tokens, options: AssemblerOptions(language: language, mode: mode))
	}

	func testAlternatingHundredsDoNotOverflow() {
		let words = ["eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf"]
		let text = words.map { "\($0) hundert" }.joined(separator: " ")
		for mode in [DictationMode.normal, .literal] {
			let output = render(text, mode: mode)
			XCTAssertFalse(output.isEmpty)
		}
		XCTAssertEqual(render("eins hundert zwei hundert", mode: .literal), "102 100")
	}

	func testRepeatedHundredStaysSmall() {
		let text = Array(repeating: "hundert", count: 20).joined(separator: " ")
		let output = render(text, mode: .literal)
		XCTAssertFalse(output.contains("10000"))
		let english = Array(repeating: "hundred", count: 25).joined(separator: " ")
		XCTAssertFalse(render(english, mode: .literal, language: "en").isEmpty)
	}

	func testFuzzedNumberWordSequencesNeverCrash() {
		let vocabulary = ["hundert", "tausend", "eins", "zwei", "neunzig", "neunhundertneunundneunzigtausend", "und", "zwölf", "Komma", "fünf"]
		var generator = SystemRandomNumberGenerator()
		for _ in 0..<300 {
			let count = Int.random(in: 1...40, using: &generator)
			let text = (0..<count).map { _ in vocabulary.randomElement(using: &generator)! }.joined(separator: " ")
			_ = render(text, mode: .literal)
			_ = render(text, mode: .normal)
		}
		let thousands = Array(repeating: "neunhundertneunundneunzigtausend tausend", count: 30).joined(separator: " ")
		XCTAssertFalse(render(thousands, mode: .literal).isEmpty)
	}

	func testStreamingProcessorSurvivesManyHundreds() {
		var processor = StreamingTextProcessor(options: .init())
		var output = ""
		for _ in 0..<20 { output += processor.push("hundert ") }
		output += processor.flush()
		XCTAssertFalse(output.isEmpty)
	}

	func testNormalNumbersUnchanged() {
		XCTAssertEqual(render("zweihundert Milligramm", mode: .literal), "200 mg")
		XCTAssertEqual(render("zwei hundert tausend", mode: .literal), "200000")
	}
}
