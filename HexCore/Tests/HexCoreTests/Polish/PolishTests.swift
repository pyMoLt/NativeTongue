import XCTest
@testable import HexCore

final class PolishGuardTests: XCTestCase {
	private func check(_ original: String, _ result: String, _ strictness: GuardStrictness = .strict, terms: [String] = []) -> [PolishGuardIssue.Kind] {
		PolishGuard.check(original: original, result: result, strictness: strictness, lengthTolerancePercent: 25, protectedTerms: terms).map(\.kind)
	}

	func testCleanEditPasses() {
		XCTAssertEqual(check("der patient bekommt 2,5 mg rivaroxaban und keine weiteren medikamente", "Der Patient bekommt 2,5 mg Rivaroxaban und keine weiteren Medikamente."), [])
	}

	func testChangedDoseIsFlagged() {
		let issues = PolishGuard.check(original: "Der Patient bekommt 2,5 mg Rivaroxaban täglich am Abend.", result: "Der Patient bekommt 25 mg Rivaroxaban täglich am Abend.", strictness: .strict, lengthTolerancePercent: 25)
		XCTAssertTrue(issues.contains(PolishGuardIssue(kind: .numberChanged, detail: "2,5 mg")))
	}

	func testDoseWithoutSpaceMatchesDoseWithSpace() {
		XCTAssertEqual(check("Gabe von 5mg Bisoprolol morgens und abends heute", "Gabe von 5 mg Bisoprolol morgens und abends heute."), [])
	}

	func testDroppedNegationIsFlagged() {
		XCTAssertTrue(check("Es gibt keinen Hinweis auf eine Thrombose im Bein", "Es gibt einen Hinweis auf eine Thrombose im Bein.").contains(.negationChanged))
	}

	func testShorteningIsFlaggedInStrictButNotInKeyFacts() {
		let original = "also ich wollte eigentlich sagen dass wir die datei ContentView.swift heute noch umbenennen sollten weil der name nicht passt"
		let rewrite = "Benenne ContentView.swift heute um, der Name passt nicht."
		XCTAssertTrue(check(original, rewrite, .strict).contains(.lengthChanged))
		XCTAssertEqual(check(original, rewrite, .keyFacts), [])
	}

	func testKeyFactsRequiresFileNameAndNumbers() {
		let original = "bitte in ContentView.swift den timeout auf 30 sekunden setzen"
		XCTAssertEqual(Set(check(original, "Bitte den Timeout erhöhen.", .keyFacts)), [.numberChanged, .codeChanged])
	}

	func testProtectedTermMustSurvive() {
		XCTAssertEqual(check("Gabe von Mycophenolatmofetil heute morgen um acht Uhr früh", "Gabe von Mycophenolat heute Morgen um acht Uhr früh.", terms: ["Mycophenolatmofetil"]), [.termChanged])
	}

	func testSpellingAndFillersDoNotCountAsShortening() {
		let input = "ähm der patient bekommt 2,5 mg rivaroxaban einmal täglich die kontrolle erfolgt in zwei wochen bitte schreibe groß a b c"
		let output = "Der Patient bekommt 2,5 mg Rivaroxaban einmal täglich. Die Kontrolle erfolgt in zwei Wochen. ABC"
		XCTAssertEqual(check(input, output), [])
	}

	func testDroppingASentenceIsStillFlagged() {
		let input = "der befund ist unauffällig und die kontrolle erfolgt in zwei wochen beim hausarzt in der praxis"
		XCTAssertTrue(check(input, "Der Befund ist unauffällig.").contains(.lengthChanged))
	}

	func testConvertedVoiceCommandsDoNotTriggerLengthWarning() {
		let original = "Befund Doppelpunkt keine Blutung Klammer auf links Klammer zu Punkt Das Wort Klammer steht im Bericht. Keine Änderung der Dosis von 2,5 mg Apixaban."
		let result = "Befund: keine Blutung (links). Das Wort Klammer steht im Bericht. Keine Änderung der Dosis von 2,5 mg Apixaban."
		XCTAssertEqual(check(original, result, .strict, terms: ["Apixaban"]), [])
		XCTAssertTrue(check(original, "Befund: keine Blutung (links). Das Wort Klammer steht im Bericht.", .strict, terms: ["Apixaban"]).contains(.termChanged))
	}

	func testDroppingOneSentenceFromLongDictationIsFlagged() {
		let first = "Die lokale App verarbeitet die Audiodatei und speichert Metadaten ohne Cloud-Aufruf."
		let middle = "The surrounding sentence remains German and the English terms should keep their normal spelling."
		let last = "Danach folgt wieder ein deutscher Satz mit Code Switching und technischen Namen."
		let original = [first, middle, last].joined(separator: " ")
		let result = [first, last].joined(separator: " ")
		XCTAssertTrue(check(original, result).contains(.lengthChanged))
	}

	func testEmptyResultIsFlagged() {
		XCTAssertEqual(check("Hallo Welt", "   "), [.empty])
	}

	func testLengthOnlyIgnoresNumbers() {
		XCTAssertEqual(check("Wir treffen uns um 10 Uhr am Bahnhof morgen früh", "Wir treffen uns um 11 Uhr am Bahnhof morgen früh.", .lengthOnly), [])
	}
}

final class PolishPromptTests: XCTestCase {
	func testCustomPromptAndPersonalNote() {
		var settings = PostProcessingSettings()
		settings.customCleanPrompt = "Fix only commas."
		settings.personalNote = "Always use British spelling."
		let system = PolishPrompt.system(for: .clean, settings: settings)
		XCTAssertTrue(system.hasPrefix("Fix only commas."))
		XCTAssertTrue(system.hasSuffix("Always use British spelling."))
	}

	func testEmptyCustomPromptFallsBackToDefault() {
		var settings = PostProcessingSettings()
		settings.customRewritePrompt = "   "
		XCTAssertEqual(PolishPrompt.system(for: .rewrite, settings: settings), PolishPrompt.defaultRewrite)
	}

	func testDefaultCleanPromptCoversSpelling() {
		XCTAssertTrue(PolishPrompt.defaultClean.contains("ABC"))
		XCTAssertTrue(PolishPrompt.defaultClean.contains("Do not rephrase"))
	}

	func testSettingsDecodeWithMissingFields() throws {
		let decoded = try JSONDecoder().decode(PostProcessingSettings.self, from: Data(#"{"enabled":true}"#.utf8))
		XCTAssertTrue(decoded.enabled)
		XCTAssertEqual(decoded.idleUnloadMinutes, 5)
		XCTAssertEqual(decoded.unloadPolicy, .afterIdle)
		XCTAssertEqual(decoded.cleanStrictness, .strict)
		XCTAssertEqual(decoded.rewriteStrictness, .keyFacts)
	}
}

final class PolishSanitizerTests: XCTestCase {
	func testStripsThinkingAndLabels() {
		let output = "<think>user wants commas</think>\nCorrected text: Hallo, Welt."
		XCTAssertEqual(PolishOutputSanitizer.clean(output, input: "hallo welt"), "Hallo, Welt.")
	}

	func testStripsUnclosedThinking() {
		XCTAssertEqual(PolishOutputSanitizer.clean("Hallo Welt.<think>and then", input: "hallo welt"), "Hallo Welt.")
	}

	func testStripsWrappingQuotesOnlyWhenInputHadNone() {
		XCTAssertEqual(PolishOutputSanitizer.clean("\"Hallo Welt.\"", input: "hallo welt"), "Hallo Welt.")
		XCTAssertEqual(PolishOutputSanitizer.clean("\"Zitat.\"", input: "\"zitat\""), "\"Zitat.\"")
	}

	func testStripsCodeFenceAndMarkers() {
		XCTAssertEqual(PolishOutputSanitizer.clean("```\nHallo Welt.\n```>>>", input: "hallo welt"), "Hallo Welt.")
	}
}

final class PolishChunkerTests: XCTestCase {
	func testShortTextIsOneChunk() {
		XCTAssertEqual(PolishChunker.chunks("Ein kurzer Text."), ["Ein kurzer Text."])
	}

	func testLongTextSplitsAtParagraphsAndSentences() {
		let sentence = Array(repeating: "Wort", count: 30).joined(separator: " ") + ". "
		let paragraph = String(repeating: sentence, count: 3)
		let text = [paragraph, paragraph, paragraph].joined(separator: "\n\n")
		let chunks = PolishChunker.chunks(text, maxWords: 100)
		XCTAssertGreaterThan(chunks.count, 1)
		XCTAssertTrue(chunks.allSatisfy { PolishGuard.words($0).count <= 100 })
		XCTAssertEqual(chunks.flatMap { PolishGuard.words($0) }.count, PolishGuard.words(text).count)
	}
}

final class WordDiffTests: XCTestCase {
	func testMarksChangedWords() {
		XCTAssertEqual(
			WordDiff.diff("der patient bekommt 25 mg", "Der Patient bekommt 25 mg."),
			[
				.init(.removed, "der patient"), .init(.added, "Der Patient"),
				.init(.same, "bekommt 25"), .init(.removed, "mg"), .init(.added, "mg."),
			]
		)
	}

	func testIdenticalTextIsOneSegment() {
		XCTAssertEqual(WordDiff.diff("a b c", "a b c"), [.init(.same, "a b c")])
	}
}
