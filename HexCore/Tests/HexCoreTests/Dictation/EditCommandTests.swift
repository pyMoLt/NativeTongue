import XCTest
@testable import HexCore

/// B1: correction commands (phrases, document edits, plain-text planner).
final class EditCommandTests: XCTestCase {
	private func command(_ text: String, english: Bool = true) -> EditCommand? {
		CommandGrammar.editCommand(text, english: english)
	}

	func testFixedPhrasesAndAsrVariants() {
		let cases: [(String, EditCommand)] = [
			("Streich das.", .deleteLastUtterance), ("streiche das", .deleteLastUtterance), ("Lösch dass!", .deleteLastUtterance),
			("Strich das", .deleteLastUtterance), ("Das war falsch.", .deleteLastUtterance), ("Scratch that.", .deleteLastUtterance),
			("That was wrong", .deleteLastUtterance),
			("Lösch das letzte Wort.", .deleteLastWord), ("Letztes Wort löschen", .deleteLastWord), ("delete the last word", .deleteLastWord),
			("Streich den letzten Satz", .deleteLastSentence), ("Letzten Satz löschen.", .deleteLastSentence),
			("Rückgängig.", .undo), ("Rückgängig machen", .undo), ("Zurück", .undo), ("Go back.", .undo),
			("Von vorn.", .clearAll), ("Noch mal von vorne!", .clearAll), ("Nochmal von vorn", .clearAll), ("Start over", .clearAll),
			("Alles löschen", .clearAll),
		]
		for (text, expected) in cases { XCTAssertEqual(command(text), expected, text) }
	}

	func testDeleteLastNWords() {
		XCTAssertEqual(command("Lösche die letzten drei Wörter."), .deleteLastWords(3))
		XCTAssertEqual(command("lösch die letzten zehn Wörter"), .deleteLastWords(10))
		XCTAssertEqual(command("Streich die letzten 4 Worte"), .deleteLastWords(4))
		XCTAssertEqual(command("Letzten zwei Wörter löschen"), .deleteLastWords(2))
		XCTAssertEqual(command("Delete the last five words."), .deleteLastWords(5))
		XCTAssertNil(command("Lösche die letzten elf Wörter"))
		XCTAssertNil(command("Lösche die letzten Wörter"))
		XCTAssertNil(command("Delete the last five words", english: false))
	}

	func testReplaceCommands() {
		XCTAssertEqual(command("Ersetze Montag durch Dienstag."), .replace("Montag", with: "Dienstag"))
		XCTAssertEqual(command("ersetz 5 mg mit 10 mg"), .replace("5 mg", with: "10 mg"))
		XCTAssertEqual(command("Ersetze „Meier“ durch „Maier“"), .replace("Meier", with: "Maier"))
		XCTAssertEqual(command("Replace Monday with Tuesday"), .replace("Monday", with: "Tuesday"))
		XCTAssertNil(command("Ersetze durch Dienstag"))
		XCTAssertNil(command("Ersetze das alte Rad an der Hinterachse vom Auto durch ein neues Rad"))
	}

	func testOrdinarySentencesAreNoCommands() {
		for text in ["Das ist nicht falsch.", "Wir gehen zurück nach Hause.", "Streich das Fenster grün.", "Lösche bitte die Datei",
		             "Undo the changes in the file", "Von vorne sah es gut aus."] {
			XCTAssertNil(command(text), text)
		}
	}

	func testDocumentDeletesLastWordsAndReplacesLastOccurrence() {
		var document = DictationDocument()
		document.append(utteranceID: 0, tokens: ModelTextTokenizer.tokenize("Termin am Montag um zehn,"))
		document.append(utteranceID: 1, tokens: ModelTextTokenizer.tokenize("dann wieder Montag Abend."))
		document.apply(.replace("Montag", with: "Dienstag"))
		let options = AssemblerOptions(language: "de", mode: .normal)
		XCTAssertEqual(document.render(options), "Termin am Montag um zehn, dann wieder Dienstag Abend.")
		document.apply(.deleteLastWords(2))
		XCTAssertEqual(document.render(options), "Termin am Montag um zehn, dann wieder")
		document.apply(.undo)
		XCTAssertEqual(document.render(options), "Termin am Montag um zehn, dann wieder Dienstag Abend.")
		document.apply(.replace("E-Mail Adresse", with: "Anschrift"))
		XCTAssertEqual(document.unappliedEdits, [.replace("E-Mail Adresse", with: "Anschrift")])
	}

	func testReplaceOfMissingWordsStaysDictation() {
		let aligned = [
			AlignedUtterance(utterance: Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: 900, pauseAfterMs: 900), text: "Der Reifen ist alt."),
			AlignedUtterance(utterance: Utterance(id: 1, range: 16_000..<32_000, pauseBeforeMs: 900, pauseAfterMs: 900), text: "Ersetze den Motor durch einen neuen."),
		]
		let document = DictationSessionProcessor.makeDocument(from: aligned, options: .init(mode: .normal, formatNumbers: false))
		XCTAssertTrue(document.render(.init(language: "de", mode: .normal)).contains("Ersetze den Motor durch einen neuen."))

		let replacing = [
			aligned[0],
			AlignedUtterance(utterance: Utterance(id: 1, range: 16_000..<32_000, pauseBeforeMs: 900, pauseAfterMs: 900), text: "Ersetze alt durch neu."),
		]
		let edited = DictationSessionProcessor.makeDocument(from: replacing, options: .init(mode: .normal, formatNumbers: false))
		XCTAssertEqual(edited.render(.init(language: "de", mode: .normal)), "Der Reifen ist neu.")

		let external = [AlignedUtterance(utterance: Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: 900, pauseAfterMs: 900), text: "Ersetze Montag durch Dienstag")]
		let target = DictationSessionProcessor.makeDocument(from: external, options: .init(mode: .normal, formatNumbers: false, editTarget: "Wir sehen uns am Montag."))
		XCTAssertEqual(target.unappliedEdits, [.replace("Montag", with: "Dienstag")])
		XCTAssertTrue(target.isEmpty)
	}

	func testPlannerEditsOnlyOwnSegments() {
		let segments = ["Hallo Welt.", " Wir treffen uns am Montag", " um zehn Uhr."]
		XCTAssertEqual(TextEditPlanner.apply(.deleteLastUtterance, to: segments), ["Hallo Welt.", " Wir treffen uns am Montag"])
		XCTAssertEqual(TextEditPlanner.apply(.deleteLastWord, to: segments)?.joined(), "Hallo Welt. Wir treffen uns am Montag um zehn")
		XCTAssertEqual(TextEditPlanner.apply(.deleteLastWords(3), to: segments)?.joined(), "Hallo Welt. Wir treffen uns am Montag")
		XCTAssertEqual(TextEditPlanner.apply(.deleteLastSentence, to: segments)?.joined(), "Hallo Welt.")
		XCTAssertEqual(TextEditPlanner.apply(.replace("montag", with: "Dienstag"), to: segments)?.joined(), "Hallo Welt. Wir treffen uns am Dienstag um zehn Uhr.")
		XCTAssertEqual(TextEditPlanner.apply(.clearAll, to: segments), [])
		XCTAssertNil(TextEditPlanner.apply(.replace("Freitag", with: "Samstag"), to: segments))
		XCTAssertNil(TextEditPlanner.apply(.deleteLastUtterance, to: []))
		XCTAssertEqual(TextEditPlanner.apply(.deleteLastWords(20), to: segments), [])
	}

	func testKeystrokesDeleteOnlyTheDifference() {
		let strokes = TextEditPlanner.keystrokes(from: "am Montag um zehn", to: "am Dienstag um zehn")
		XCTAssertEqual(strokes.delete, 14)
		XCTAssertEqual(strokes.insert, "Dienstag um zehn")
		XCTAssertEqual(TextEditPlanner.keystrokes(from: "Hallo 👍🏽 Welt", to: "Hallo 👍🏽").delete, 5)
	}
}
