import XCTest
@testable import HexCore

/// Plan B5: gold corpus for spoken numbers (≥ 80 cases, DE/EN, Literal and Normal).
final class NumberGoldTests: XCTestCase {
	private func render(_ text: String, _ language: String, _ mode: DictationMode) -> String {
		let tokens = DictationTextPipeline.process(text, options: .init(mode: mode, language: language, agentFormatting: false))
		return Assembler.render(tokens, options: AssemblerOptions(language: language, mode: mode))
	}

	private let german: [(String, String)] = [
		// Units and decimals
		("zwei Komma fünf Milligramm", "2,5 mg"), ("null Komma fünf Milligramm pro Kilogramm", "0,5 mg/kg"),
		("zehn Prozent", "10 %"), ("dreitausend internationale Einheiten", "3000 IE"), ("neununddreißig Komma zwei Grad Celsius", "39,2 °C"),
		("hundertvierzig zu neunzig Millimeter Quecksilbersäule", "140 zu 90 mmHg"), ("fünf Milliliter", "5 ml"),
		("zwanzig Mikrogramm", "20 µg"), ("drei Kilogramm", "3 kg"), ("sechzig Schläge pro Minute", "60 /min"),
		// Plain numbers
		("dreizehn Patienten", "13 Patienten"), ("zwei Antworten", "Zwei Antworten"), ("hundertzwanzig Seiten", "120 Seiten"),
		("zweitausendsechsundzwanzig", "2026"), ("eine Frage", "Eine Frage"),
		// Dates
		("am dritten März zweitausendsechsundzwanzig", "Am 03.03.2026"), ("am ersten Mai", "Am 01.05."),
		("am einunddreißigsten Dezember neunzehnhundertneunzig", "Am 31.12.1990"), ("bis zum zwanzigsten Juni", "Bis zum 20.06."),
		("der dritte Patient im Mai", "Der dritte Patient im Mai"), ("am 3.3.", "Am 3.3"),
		// Times
		("um acht Uhr", "Um 8 Uhr"), ("um vierzehn Uhr dreißig", "Um 14:30 Uhr"), ("um 14 Uhr 30", "Um 14:30 Uhr"),
		("um halb drei", "Um 2:30 Uhr"), ("um viertel nach acht", "Um 8:15 Uhr"), ("um viertel vor neun", "Um 8:45 Uhr"),
		("um dreiviertel neun", "Um 8:45 Uhr"), ("um null Uhr", "Um 0 Uhr"), ("um zwölf Uhr fünfzehn", "Um 12:15 Uhr"),
		("halb zwölf", "11:30 Uhr"),
		// Money
		("zwölf Euro fünfzig", "12,50 €"), ("zwölf Euro und fünfzig Cent", "12,50 €"), ("drei Euro", "3 €"),
		("hundert Euro", "100 €"), ("zwei Komma fünf Euro", "2,5 €"), ("zwanzig Dollar", "20 $"), ("fünf Pfund", "5 £"),
		("vier Euro neunundneunzig", "4,99 €"),
		// Ordinals
		("der zwanzigste Patient", "Der 20. Patient"), ("zum dreizehnten Mal", "Zum 13. Mal"), ("die hundertste Seite", "Die 100. Seite"),
		("der zweite Versuch", "Der zweite Versuch"), ("achten Sie darauf", "Achten Sie darauf"),
		// Phone numbers
		("null eins sieben eins zwei drei vier fünf sechs sieben acht", "0171 2345678"),
		("null drei null eins zwei drei vier fünf sechs", "030 123456"),
		("plus vier neun eins sieben eins zwei drei vier fünf", "+49 1712345"),
		("eins zwei drei vier fünf sechs", "Eins zwei drei vier fünf sechs"),
		// House numbers
		("Hauptstraße zwölf a", "Hauptstraße 12a"), ("Am Ring drei b", "Am Ring 3b"), ("Hausnummer siebzehn c", "Hausnummer 17c"),
		("Lindenweg vier", "Lindenweg 4"), ("Gartenstraße einundzwanzig", "Gartenstraße 21"),
	]

	private let english: [(String, String)] = [
		("two point five milligrams", "2.5 mg"), ("ten percent", "10%"), ("twenty-five cases", "25 cases"),
		("one of three options", "One of three options"), ("thirteen patients", "13 patients"),
		("on March third twenty twenty-six", "On March 3, 2026"), ("on the third of March", "On March 3"),
		("at eight o'clock", "At 8 o'clock"), ("at half past eight", "At 8:30"), ("at quarter past nine", "At 9:15"),
		("at quarter to nine", "At 8:45"), ("at eight thirty pm", "At 8:30 pm"), ("at seven am", "At 7 am"),
		("twelve dollars fifty", "$12.50"), ("five euros", "€5"), ("twenty pounds", "£20"), ("ninety-nine cents", "99 cents"),
		("the twentieth patient", "The 20th patient"), ("the twenty-first case", "The 21st case"), ("the second try", "The second try"),
		("zero one seven one two three four five six", "017123456"), ("five five five one two three four five six seven", "555-123-4567"),
		("one two three four five", "One two three four five"), ("Main Street twelve b", "Main Street 12b"),
		("three hundred grams", "300 g"), ("forty micrograms", "40 µg"), ("seventy beats per minute", "70 bpm"),
		("thirty-eight point five degrees celsius", "38.5 °C"),
	]

	func testGermanLiteral() {
		for (input, expected) in german { XCTAssertEqual(render(input, "de", .literal), expected, input) }
	}

	func testEnglishLiteral() {
		for (input, expected) in english { XCTAssertEqual(render(input, "en", .literal), expected, input) }
	}

	func testNormalModeValues() {
		let cases: [(String, String, String)] = [
			("Wir treffen uns um halb drei.", "de", "Wir treffen uns um 2:30 Uhr."),
			("Das kostet zwölf Euro fünfzig.", "de", "Das kostet 12,50 €."),
			("Ruf mich an unter null eins sieben eins zwei drei vier fünf sechs sieben acht.", "de", "Ruf mich an unter 0171 2345678."),
			("Er bekam 2,5 Milligramm.", "de", "Er bekam 2,5 mg."),
			("Meet me at half past eight.", "en", "Meet me at 8:30."),
		]
		for (input, language, expected) in cases { XCTAssertEqual(render(input, language, .normal), expected, input) }
	}

	func testCorpusSize() {
		XCTAssertGreaterThanOrEqual(german.count + english.count + 5, 80)
	}
}
