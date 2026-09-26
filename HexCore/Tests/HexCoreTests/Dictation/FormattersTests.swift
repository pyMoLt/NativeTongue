import XCTest
@testable import HexCore

final class NumberFormatterTests: XCTestCase {
	private func de(_ text: String, mode: DictationMode = .literal) -> String {
		let tokens = DictationTextPipeline.process(text, options: .init(mode: mode, language: "de"))
		return Assembler.render(tokens, options: AssemblerOptions(language: "de", mode: mode))
	}

	private func en(_ text: String, mode: DictationMode = .literal) -> String {
		let tokens = DictationTextPipeline.process(text, options: .init(mode: mode, language: "en"))
		return Assembler.render(tokens, options: AssemblerOptions(language: "en", mode: mode))
	}

	func testGermanCompounds() {
		let cases: [(String, Int)] = [
			("null", 0), ("eins", 1), ("zwölf", 12), ("dreizehn", 13), ("siebzehn", 17), ("zwanzig", 20),
			("einundzwanzig", 21), ("dreiundvierzig", 43), ("neunundneunzig", 99), ("hundert", 100),
			("einhundert", 100), ("hundertzwei", 102), ("zweihundertfünfundvierzig", 245), ("tausend", 1_000),
			("eintausend", 1_000), ("zweitausendsechsundzwanzig", 2_026), ("dreitausendvierhundertelf", 3_411),
			("neunhundertneunundneunzigtausendneunhundertneunundneunzig", 999_999),
		]
		for (word, value) in cases {
			XCTAssertEqual(SpokenNumberFormatter.germanCompound(word), value, word)
		}
		for word in ["und", "hundertund", "dreißigund", "einig", "frage", "achtung"] {
			XCTAssertNil(SpokenNumberFormatter.germanCompound(word), word)
		}
	}

	func testDosageAndDecimals() {
		XCTAssertEqual(de("zwei Komma fünf Milligramm"), "2,5 mg")
		XCTAssertEqual(de("Apixaban fünf Milligramm"), "Apixaban 5 mg")
		XCTAssertEqual(de("null Komma fünf Milligramm pro Kilogramm"), "0,5 mg/kg")
		XCTAssertEqual(de("Blutdruck hundertvierzig zu neunzig Millimeter Quecksilbersäule"), "Blutdruck 140 zu 90 mmHg")
		XCTAssertEqual(de("Fieber neununddreißig Komma zwei Grad Celsius"), "Fieber 39,2 °C")
		XCTAssertEqual(de("zehn Prozent"), "10 %")
		XCTAssertEqual(de("dreitausend internationale Einheiten"), "3000 IE")
		XCTAssertEqual(en("two point five milligrams"), "2.5 mg")
		XCTAssertEqual(en("ten percent"), "10%")
	}

	func testSmallNumbersWithoutUnitStayWords() {
		XCTAssertEqual(de("eine Frage und zwei Antworten"), "Eine Frage und zwei Antworten")
		XCTAssertEqual(de("gib acht"), "Gib acht")
		XCTAssertEqual(de("dreizehn Patienten"), "13 Patienten")
		XCTAssertEqual(en("one of three options"), "One of three options")
		XCTAssertEqual(en("twenty-five cases"), "25 cases")
	}

	func testDecimalCommaIsNotPunctuationInLiteral() {
		XCTAssertEqual(de("Wert zwei Komma fünf Komma dann weiter"), "Wert 2,5, dann weiter")
	}

	func testDates() {
		XCTAssertEqual(de("am dritten März zweitausendsechsundzwanzig"), "Am 03.03.2026")
		XCTAssertEqual(de("am ersten Mai"), "Am 01.05.")
		XCTAssertEqual(de("am einunddreißigsten Dezember neunzehnhundertneunzig"), "Am 31.12.1990")
		XCTAssertEqual(en("on March third twenty twenty-six"), "On March 3, 2026")
		XCTAssertEqual(de("der dritte Patient im Mai"), "Der dritte Patient im Mai")
	}

	func testNormalModeKeepsModelDigits() {
		XCTAssertEqual(de("Er bekam 2,5 Milligramm.", mode: .normal), "Er bekam 2,5 mg.")
	}
}

final class AgentFormatterTests: XCTestCase {
	private func run(_ text: String) -> String {
		let tokens = DictationTextPipeline.process(text, options: .init(mode: .normal, language: "de"))
		return Assembler.render(tokens, options: AssemblerOptions(language: "de", mode: .normal))
	}

	func testFileNames() {
		XCTAssertEqual(run("öffne ContentView Punkt swift und prüfe das"), "öffne ContentView.swift und prüfe das")
		XCTAssertEqual(run("lies README Punkt md"), "lies README.md")
		XCTAssertEqual(run("Das ist ein Punkt in der Liste"), "Das ist ein Punkt in der Liste")
	}

	func testCaseStyles() {
		XCTAssertEqual(run("benenne camel case user name um"), "benenne userName um")
		XCTAssertEqual(run("Klasse Pascal Case audio import feature anlegen"), "Klasse AudioImportFeature anlegen")
		XCTAssertEqual(run("Variable snake case max tokens"), "Variable max_tokens")
		XCTAssertEqual(run("Branch kebab case phase one core"), "Branch phase-one-core")
		XCTAssertEqual(run("camel case very long identifier name here Ende fertig"), "veryLongIdentifierNameHere fertig")
	}

	func testBackticksCodeAndSlash() {
		XCTAssertEqual(run("rufe Backtick swift test Backtick auf"), "rufe `swift test` auf")
		XCTAssertEqual(run("nutze Code git status Code Ende bitte"), "nutze `git status` bitte")
		XCTAssertEqual(run("Slash review bitte"), "/review bitte")
		XCTAssertEqual(run("setze max Unterstrich tokens"), "setze max_tokens")
	}
}

private extension String {
	var lowercasedFirstForTest: String { prefix(1).lowercased() + dropFirst() }
}

final class TokenizerAndGuardTests: XCTestCase {
	func testTokenizerKeepsSpecialWords() {
		let tokens = ModelTextTokenizer.tokenize("(Alpha, z.B. 2,5 mg um 10:30 Uhr) - fertig.")
		XCTAssertEqual(tokens, [
			.modelMark("(", .opening), .word("Alpha"), .modelMark(",", .closing), .word("z.B."), .word("2,5"), .word("mg"),
			.word("um"), .word("10:30"), .word("Uhr"), .modelMark(")", .closing), .modelMark("–", .spaced),
			.word("fertig"), .modelMark(".", .closing),
		])
	}

	func testNormalModeRoundTripsModelPunctuation() {
		let text = "Ja, das ist (fast) fertig – oder? Ja."
		let tokens = DictationTextPipeline.process(text, options: .init(mode: .normal, agentFormatting: false))
		XCTAssertEqual(Assembler.render(tokens, options: AssemblerOptions(mode: .normal)), text)
	}

	func testBiasLeakGuardFindsCopiedList() {
		let bias = ["Tinea corporis", "Mycophenolatmofetil", "Pembrolizumab", "Apixaban", "Rivaroxaban", "Glomerulonephritis",
		            "Urothelkarzinom", "AVFoundation", "PostgreSQL", "FluidAudio", "Qwen", "Hugging Face", "GitHub"]
		let text = "Weitere medizinische Prüfwörter sind Nervos, Tinea corporis, Mycophenolatmofetil, Pembrolizumab, Apixaban, Rivaroxaban, Glomerulonephritis, Urothelkarzinom, AVFoundation, PostgreSQL, FluidAudio, Qwen, Hugging Face, GitHub. Lizumab, Apixaban"
		let range = try? XCTUnwrap(BiasLeakGuard.leakedRange(in: text, biasTerms: bias))
		XCTAssertNotNil(range)
		if let range {
			XCTAssertTrue(text[range].hasPrefix("Tinea corporis"))
			XCTAssertTrue(text[range].contains("GitHub"))
		}
		XCTAssertNil(BiasLeakGuard.leakedRange(in: "Der Patient erhielt Apixaban und später Rivaroxaban.", biasTerms: bias))
	}
}
