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

	func testDroppedReminderIsNotANegation() {
		let original = "dann den arztbrief fertig machen und nicht vergessen die überweisung zur kardiologie raus zu schicken"
		let rewrite = "- Arztbrief fertig machen\n- Überweisung zur Kardiologie verschicken"
		XCTAssertEqual(check(original, rewrite, .keyFacts), [])
		XCTAssertEqual(check("don't forget to push the tag and update the readme", "- Push the tag\n- Update the README", .keyFacts), [])
		// An exception keeps the meaning of a negation.
		XCTAssertEqual(check("alte backups löschen aber nicht die vom monatsende", "- Alte Backups löschen, außer die vom Monatsende", .keyFacts), [])
		// A real negation next to a reminder still counts.
		XCTAssertTrue(check("nicht vergessen: kein ibuprofen mehr geben", "- Ibuprofen geben", .keyFacts).contains(.negationChanged))
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
	func testEditedStylePromptExampleAndPersonalNote() {
		var settings = PostProcessingSettings()
		var clean = settings.style(id: AIStyleCatalog.cleanID)
		clean.instruction = "Fix only commas."
		clean.exampleInput = "a b"
		clean.exampleOutput = "a, b"
		settings.save(clean)
		settings.personalNote = "Always use British spelling."
		let system = PolishPrompt.system(for: settings.style(id: AIStyleCatalog.cleanID), settings: settings)
		XCTAssertTrue(system.hasPrefix("Fix only commas."))
		XCTAssertTrue(system.contains("Example input: a b\nExample output:\na, b"))
		XCTAssertTrue(system.hasSuffix("Always use British spelling."))
		XCTAssertTrue(settings.isEdited(AIStyleCatalog.cleanID))
		settings.restoreDefault(AIStyleCatalog.cleanID)
		XCTAssertEqual(PolishPrompt.system(for: settings.style(id: AIStyleCatalog.cleanID), settings: PostProcessingSettings()), PolishPrompt.defaultClean)
	}

	func testEmptyInstructionFallsBackToDefault() {
		var task = AIStyleCatalog.builtIn(id: AIStyleCatalog.taskID)!
		task.instruction = "   "
		XCTAssertEqual(PolishPrompt.system(for: task, settings: PostProcessingSettings()), PolishPrompt.defaultRewrite)
	}

	func testContextIsAddedAsReference() {
		let system = PolishPrompt.system(for: AIStyleCatalog.builtIns[0], settings: PostProcessingSettings(), context: "Context (reference only): app Mail")
		XCTAssertTrue(system.contains("Context (reference only): app Mail"))
	}

	func testCustomStylesAndDeletion() {
		var settings = PostProcessingSettings()
		var mine = AIStyle.newCustom(name: "Protocol")
		mine.instruction = "Write a protocol."
		settings.save(mine)
		settings.boxStyleID = mine.id
		XCTAssertEqual(settings.allStyles.count, AIStyleCatalog.builtIns.count + 1)
		XCTAssertEqual(settings.boxStyle.name, "Protocol")
		XCTAssertTrue(settings.boxStyle.isCustom)
		settings.deleteStyle(mine.id)
		XCTAssertEqual(settings.boxStyleID, AIStyleCatalog.cleanID)
		settings.deleteStyle(AIStyleCatalog.cleanID)
		XCTAssertEqual(settings.allStyles.count, AIStyleCatalog.builtIns.count, "built-in styles cannot be deleted")
		XCTAssertEqual(settings.style(id: "unknown").id, AIStyleCatalog.cleanID)
	}

	func testOffStrictnessSkipsTheCheck() {
		XCTAssertEqual(PolishGuard.check(original: "Es gibt 3 Befunde und keine Blutung heute", result: "- Befunde", strictness: .off, lengthTolerancePercent: 25), [])
		XCTAssertEqual(PolishGuard.check(original: "Text", result: "  ", strictness: .off, lengthTolerancePercent: 25).map(\.kind), [.empty])
	}

	func testDefaultCleanPromptCoversSpelling() {
		XCTAssertTrue(PolishPrompt.defaultClean.contains("ABC"))
		XCTAssertTrue(PolishPrompt.defaultClean.contains("Do not rephrase"))
	}

	func testDefaultRewritePromptKeepsNegationsAndRecipients() {
		XCTAssertTrue(PolishPrompt.defaultRewrite.contains("kein Ibuprofen mehr geben"))
		XCTAssertTrue(PolishPrompt.defaultRewrite.contains("recipients"))
		XCTAssertTrue(PolishPrompt.defaultRewrite.contains("no \"Sie\" form"))
	}

	func testSettingsDecodeWithMissingFields() throws {
		let decoded = try JSONDecoder().decode(PostProcessingSettings.self, from: Data(#"{"enabled":true}"#.utf8))
		XCTAssertTrue(decoded.enabled)
		XCTAssertEqual(decoded.idleUnloadMinutes, 5)
		XCTAssertEqual(decoded.unloadPolicy, .afterIdle)
		XCTAssertEqual(decoded.autoStyle.strictness, .strict)
		XCTAssertEqual(decoded.style(id: AIStyleCatalog.taskID).strictness, .keyFacts)
		XCTAssertTrue(decoded.editedStyles.isEmpty)
	}

	func testPre26SettingsMoveOntoStyles() throws {
		let json = #"{"enabled":true,"autoMode":"rewrite","boxDefaultMode":"clean","customCleanPrompt":"Only commas.","rewriteStrictness":"lengthOnly","lengthTolerancePercent":40,"cleanMaxOutputFactor":1.8,"autoStyleIDx":1}"#
		let decoded = try JSONDecoder().decode(PostProcessingSettings.self, from: Data(json.utf8))
		XCTAssertEqual(decoded.autoStyleID, AIStyleCatalog.taskID)
		XCTAssertEqual(decoded.boxStyleID, AIStyleCatalog.cleanID)
		XCTAssertEqual(decoded.style(id: AIStyleCatalog.cleanID).instruction, "Only commas.")
		XCTAssertEqual(decoded.style(id: AIStyleCatalog.cleanID).outputFactor, 1.8)
		XCTAssertEqual(decoded.style(id: AIStyleCatalog.cleanID).lengthTolerancePercent, 40)
		XCTAssertEqual(decoded.style(id: AIStyleCatalog.taskID).strictness, .lengthOnly)
		// Round trip keeps the migrated values and drops the legacy keys.
		let again = try JSONDecoder().decode(PostProcessingSettings.self, from: JSONEncoder().encode(decoded))
		XCTAssertEqual(again, decoded)
		XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("\"autoMode\""))
	}

	func testUnknownValuesDoNotBreakDecoding() throws {
		let json = #"{"enabled":true,"autoScope":"future","unloadPolicy":"sometimes","customStyles":[{"id":"custom-1","name":"X","instruction":"Y","strictness":"paranoid"}]}"#
		let decoded = try JSONDecoder().decode(PostProcessingSettings.self, from: Data(json.utf8))
		XCTAssertTrue(decoded.enabled)
		XCTAssertEqual(decoded.autoScope, .normalOnly)
		XCTAssertEqual(decoded.unloadPolicy, .afterIdle)
		XCTAssertEqual(decoded.customStyles.first?.strictness, .keyFacts)
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

	/// Audit M11: a long paragraph split at sentences must not gain paragraph breaks.
	func testJoinKeepsParagraphStructureExactly() {
		let sentences = (1...40).map { "Satz Nummer \($0) hat ein paar Wörter." }.joined(separator: " ")
		let text = sentences + "\n\nKurzer Absatz am Ende."
		let split = PolishChunker.split(text, maxWords: 60)
		XCTAssertGreaterThan(split.chunks.count, 2)
		let joined = PolishChunker.join(split.chunks, separators: split.separators)
		XCTAssertEqual(joined.components(separatedBy: "\n\n").count, 2)
		XCTAssertEqual(joined, text)
	}

	func testJoinOfPartialResultsUsesTheRightSeparators() {
		let text = "Erster Absatz.\n\nZweiter Absatz."
		let split = PolishChunker.Split(chunks: ["Erster Absatz.", "Zweiter Absatz."], separators: ["\n\n", ""])
		XCTAssertEqual(PolishChunker.join(split.chunks, separators: split.separators), text)
		XCTAssertEqual(PolishChunker.join(["Erster Absatz."], separators: split.separators), "Erster Absatz.")
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

final class AIStyleCatalogTests: XCTestCase {
	func testBuiltInsAreCompleteAndDistinct() {
		let ids = AIStyleCatalog.builtIns.map(\.id)
		XCTAssertEqual(Set(ids).count, ids.count)
		XCTAssertEqual(ids, ["clean", "clean-sentences", "task", "key-facts", "email", "message", "note", "prompt"])
		XCTAssertEqual(AIStyleCatalog.builtIn(id: "clean")?.instruction, PolishPrompt.defaultClean)
		XCTAssertEqual(AIStyleCatalog.builtIn(id: "key-facts")?.strictness, .off, "a fact list is much shorter by design")
		XCTAssertTrue(AIStyleCatalog.builtIn(id: "clean")!.chunked)
	}

	func testOneOffInstruction() {
		let style = AIStyle.oneOff(instruction: "  List all open questions ")
		XCTAssertTrue(style.instruction.contains("Instruction: List all open questions"))
		XCTAssertEqual(style.strictness, .off)
		XCTAssertTrue(style.isCustom)
	}
}

final class ContextAnalyzerTests: XCTestCase {
	private let general: (String, String) -> Bool = { word, _ in
		["Nachricht", "Projekt", "Termin", "Grüße", "Dank", "Bericht", "Meier"].contains(word)
	}

	func testAnalysesPositionAddressLanguageTermsAndLists() {
		let mail = AIContext(appName: "Mail", textBeforeCursor: "Sehr geehrte Frau Dr. Meier,\n\nvielen Dank für Ihre Nachricht zum Projekt Aurora und den Bericht von SwiftUI-Team. Wir")
		let hints = ContextAnalyzer.analyze(mail, isGeneralWord: general)
		XCTAssertEqual(hints.position, .midSentence)
		XCTAssertTrue(hints.needsLeadingSpace)
		XCTAssertEqual(hints.address, .formal)
		XCTAssertEqual(hints.language, "de")
		XCTAssertTrue(hints.terms.contains("Aurora"))
		XCTAssertTrue(hints.terms.contains("SwiftUI-Team"))
		XCTAssertTrue(hints.terms.contains("Meier"))
		XCTAssertFalse(hints.terms.contains("Nachricht"), "ordinary words are not terms")
		XCTAssertFalse(hints.terms.contains("Ihre"))

		let list = ContextAnalyzer.analyze(AIContext(textBeforeCursor: "Einkauf:\n- Milch\n- "))
		XCTAssertEqual(list.listMarker, "- ")
		XCTAssertEqual(list.position, .midSentence)
		XCTAssertFalse(list.needsLeadingSpace)

		let chat = ContextAnalyzer.analyze(AIContext(textBeforeCursor: "hey, hast du morgen zeit? "))
		XCTAssertEqual(chat.address, .informal)
		XCTAssertEqual(chat.position, .sentenceStart)
		XCTAssertFalse(chat.needsLeadingSpace)

		XCTAssertEqual(ContextAnalyzer.analyze(AIContext(appName: "ChatGPT", textBeforeCursor: "")).position, .empty)
	}

	func testContinuationFitsCapitalsAndSpace() {
		var mid = ContextHints()
		mid.position = .midSentence
		mid.needsLeadingSpace = true
		XCTAssertEqual(ContextAnalyzer.adaptInsertion("Und dann gehen wir.", hints: mid), " und dann gehen wir.")
		XCTAssertEqual(ContextAnalyzer.adaptInsertion("Patienten kommen.", hints: mid), " Patienten kommen.", "German nouns keep their capital")
		XCTAssertEqual(ContextAnalyzer.adaptInsertion("Sie kommen morgen.", hints: mid), " Sie kommen morgen.", "formal Sie keeps its capital")
		XCTAssertEqual(ContextAnalyzer.adaptInsertion(", danke.", hints: mid), ", danke.", "no space before punctuation")
		var start = ContextHints()
		start.position = .sentenceStart
		XCTAssertEqual(ContextAnalyzer.adaptInsertion("morgen geht es los.", hints: start), "Morgen geht es los.")
		XCTAssertEqual(ContextAnalyzer.adaptInsertion("so bleibt es", hints: ContextHints()), "so bleibt es", "nothing known, nothing changed")
	}

	func testTermsFromTheFieldFixSpelling() {
		let fixed = ContextAnalyzer.applyTerms("das projekt aurora mit herrn maier und dem swiftui-team", terms: ["Aurora", "Meier", "SwiftUI-Team"])
		XCTAssertEqual(fixed, "das projekt Aurora mit herrn Meier und dem SwiftUI-Team", "the spelling written in the field wins")
		XCTAssertEqual(ContextAnalyzer.applyTerms("mit Ina", terms: ["Ida"]), "mit Ina", "short words change only on the same spelling")
		XCTAssertEqual(ContextAnalyzer.applyTerms("Rivaroxabahn ist neu", terms: ["Rivaroxaban"]), "Rivaroxaban ist neu", "same sound, close spelling")
		XCTAssertEqual(ContextAnalyzer.applyTerms("ein Bericht", terms: ["Berichte"], isGeneralWord: { w, _ in w == "Bericht" }), "ein Bericht", "dictionary words stay")
	}

	func testPromptContainsOnlyDerivedHintsUnlessExperimental() {
		let context = AIContext(appName: "Mail", profileName: "Mail", textBeforeCursor: "Sehr geehrte Frau Meier, wir haben das Projekt Aurora")
		let hints = ContextAnalyzer.analyze(context)
		var settings = ContextSettings()
		XCTAssertNil(ContextAnalyzer.prompt(hints, context: context, settings: settings), "off by default")
		settings.use = .appOnly
		let appOnly = ContextAnalyzer.prompt(hints, context: context, settings: settings)!
		XCTAssertTrue(appOnly.contains("“Mail”"))
		XCTAssertFalse(appOnly.contains("Aurora"))
		settings.use = .analyzed
		let analyzed = ContextAnalyzer.prompt(hints, context: context, settings: settings)!
		XCTAssertTrue(analyzed.contains("reference only"))
		XCTAssertTrue(analyzed.contains("formally (Sie)"))
		XCTAssertTrue(analyzed.contains("Aurora"))
		XCTAssertFalse(analyzed.contains("wir haben das"), "no raw text")
		settings.sendNearbyText = true
		XCTAssertTrue(ContextAnalyzer.prompt(hints, context: context, settings: settings)!.contains("wir haben das Projekt"))
		settings.terms = false
		settings.sendNearbyText = false
		XCTAssertFalse(ContextAnalyzer.prompt(hints, context: context, settings: settings)!.contains("Aurora"))
	}

	func testSettingsDecodeTolerantlyAndClampCharacters() throws {
		let decoded = try JSONDecoder().decode(ContextSettings.self, from: Data(#"{"use":"telepathy","characters":5000,"terms":false}"#.utf8))
		XCTAssertEqual(decoded.use, .off)
		XCTAssertEqual(decoded.characters, 1000)
		XCTAssertFalse(decoded.terms)
	}
}
