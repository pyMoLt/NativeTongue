import XCTest
@testable import HexCore

/// Plan B2: self-corrections (≥ 30 positive and ≥ 30 negative cases, DE/EN).
final class SelfCorrectionTests: XCTestCase {
	private func resolve(_ text: String, language: String = "de", vocabulary: Set<String> = []) -> String {
		let tokens = SelfCorrectionResolver.resolve(ModelTextTokenizer.tokenize(text), language: language, vocabulary: vocabulary)
		return Assembler.render(tokens, options: AssemblerOptions(language: language, mode: .normal))
	}

	private let vocabulary: Set<String> = ["rivaroxaban", "apixaban", "meier", "maier", "xcode", "swiftui"]

	func testPositiveGerman() {
		let cases: [(String, String)] = [
			("Wir treffen uns am Dienstag, nein, am Mittwoch.", "Wir treffen uns am Mittwoch."),
			("Wir treffen uns am Dienstag, nein, Mittwoch.", "Wir treffen uns am Mittwoch."),
			("Am Montag, ich meine, am Freitag geht es los.", "Am Freitag geht es los."),
			("Der Termin ist Donnerstag, äh nein, Freitag.", "Der Termin ist Freitag."),
			("Komm um drei Uhr, nein, um vier Uhr.", "Komm um vier Uhr."),
			("Das Meeting beginnt um 14:30, nein warte, um 15:00.", "Das Meeting beginnt um 15:00."),
			("Wir starten halb drei, besser gesagt halb vier.", "Wir starten halb vier."),
			("Abholung viertel nach acht, nein, viertel nach neun.", "Abholung viertel nach neun."),
			("Geben Sie fünf Milligramm, nein, zehn Milligramm.", "Geben Sie zehn Milligramm."),
			("Geben Sie 5 mg, ich meine 10 mg.", "Geben Sie 10 mg."),
			("Ich brauche drei, nein, vier Stück.", "Ich brauche vier Stück."),
			("Es kostet zwanzig, sorry, dreißig Euro.", "Es kostet dreißig Euro."),
			("Der Liefertermin ist der dritte März, nein, der vierte März.", "Der Liefertermin ist der vierte März."),
			("Abgabe am 3.3., nein, am 4.3.", "Abgabe am 4.3."),
			("Im Mai, nein, im Juni fahren wir.", "Im Juni fahren wir."),
			("Der Patient bekommt Rivaroxaban, nein, Apixaban.", "Der Patient bekommt Apixaban."),
			("Bitte an Herrn Meier, ich meine Maier schicken.", "Bitte an Herrn Maier schicken."),
			("Nimm den roten, nein, den blauen Ordner.", "Nimm den blauen Ordner."),
			("Das Projekt nutzt Xcode, besser gesagt SwiftUI.", "Das Projekt nutzt SwiftUI."),
			("Wir sehen uns am Sonntag nein am Samstag", "Wir sehen uns am Samstag"),
			("Zwei Tabletten, nein, drei Tabletten täglich.", "Drei Tabletten täglich."),
			("Treffpunkt um zehn Uhr, nein warte, um elf Uhr.", "Treffpunkt um elf Uhr."),
		]
		for (input, expected) in cases { XCTAssertEqual(resolve(input, vocabulary: vocabulary), expected, input) }
	}

	func testPositiveEnglish() {
		let cases: [(String, String)] = [
			("Let's meet on Tuesday, no wait, on Wednesday.", "Let's meet on Wednesday."),
			("Let's meet on Tuesday, I mean Wednesday.", "Let's meet on Wednesday."),
			("Call me at three o'clock, sorry, at four o'clock.", "Call me at four o'clock."),
			("The dose is 5 mg, actually 10 mg.", "The dose is 10 mg."),
			("We need two, no wait, three chairs.", "We need three chairs."),
			("The deadline is March third, I mean March fourth.", "The deadline is March fourth."),
			("Send it in May, sorry, in June.", "Send it in June."),
			("Use Apixaban, I mean Rivaroxaban.", "Use Rivaroxaban."),
			("Pick the red, no wait, the blue folder.", "Pick the blue folder."),
			("It starts at 9:30, actually 10:15.", "It starts at 10:15."),
		]
		for (input, expected) in cases { XCTAssertEqual(resolve(input, language: "en", vocabulary: vocabulary), expected, input) }
	}

	func testNegativeGerman() {
		let unchanged = [
			"Nein, das stimmt nicht.",
			"Ich meine, dass wir früher anfangen sollten.",
			"Er hat nein gesagt.",
			"Ich sage nein zu diesem Vorschlag.",
			"Kommst du am Dienstag? Nein, am Mittwoch.",
			"Das Essen war gut, ich meine, sehr gut.",
			"Sorry, ich bin zu spät.",
			"Es tut mir leid, sorry.",
			"Die Antwort war nein, leider.",
			"Ich meine meine Mutter.",
			"Besser gesagt, wir wissen es nicht.",
			"Nein danke, ich habe schon gegessen.",
			"Sie sagte nein und ging.",
			"Am Dienstag geht es nicht, nein.",
			"Wir brauchen drei Stühle, nein, wir brauchen Tische.",
			"Er kam um drei, nein, er kam gar nicht.",
			"Ich meine es ernst.",
			"Das ist nein, das ist kein Fehler.",
			"Fünf Milligramm, nein, das ist zu viel.",
			"Die Dosis war 5 mg, nein, wir lassen sie.",
			"Gib 5 mg, nein, 10.",
			"Montag ist frei, nein wirklich.",
			"Der rote Ordner liegt da, nein, im Schrank.",
		]
		for text in unchanged { XCTAssertEqual(resolve(text, vocabulary: vocabulary), text, text) }
	}

	func testNegativeEnglish() {
		let unchanged = [
			"No, that is not right.",
			"I mean, we should start earlier.",
			"Sorry, I am late.",
			"He actually said yes.",
			"Do you come on Tuesday? No wait, I forgot.",
			"I mean it.",
			"It was good, I mean, really good.",
			"Actually, the meeting is cancelled.",
			"We need two chairs, sorry, we need tables.",
			"The dose was 5 mg, actually we stop it.",
		]
		for text in unchanged { XCTAssertEqual(resolve(text, language: "en", vocabulary: vocabulary), text, text) }
	}

	func testPipelineRunsBeforeNumbers() {
		let tokens = DictationTextPipeline.process(
			"Geben Sie zwei Komma fünf Milligramm, nein, drei Komma fünf Milligramm.",
			options: .init(mode: .normal, language: "de", resolveSelfCorrections: true)
		)
		XCTAssertEqual(Assembler.render(tokens, options: AssemblerOptions(language: "de", mode: .normal)), "Geben Sie 3,5 mg.")
		let off = DictationTextPipeline.process("am Dienstag, nein, am Mittwoch", options: .init(mode: .normal, language: "de"))
		XCTAssertEqual(Assembler.render(off, options: AssemblerOptions(language: "de", mode: .normal)), "am Dienstag, nein, am Mittwoch")
	}
}
