import XCTest
@testable import HexCore

/// Plan B6: text snippets.
final class SnippetTests: XCTestCase {
	private let address = TextSnippet(trigger: "meine Adresse", text: "Alex Example\n123 Example Street\n10115 Berlin")
	private let signoff = TextSnippet(trigger: "Grußformel", text: "Viele Grüße\n\nAlex")
	private let dated = TextSnippet(trigger: "Datum heute", text: "Stand: {date}, {time}")

	private func document(_ utterances: [(String, Int, Int)], snippets: [TextSnippet], mode: DictationMode = .normal) -> String {
		var options = DictationSessionOptions(mode: mode, formatNumbers: false, agentFormatting: false)
		options.snippets = TextSnippet.table(snippets, at: Date(timeIntervalSince1970: 0), language: "de")
		let aligned = utterances.enumerated().map { index, item in
			AlignedUtterance(utterance: Utterance(id: index, range: (index * 16_000)..<((index + 1) * 16_000), pauseBeforeMs: item.1, pauseAfterMs: item.2), text: item.0)
		}
		return DictationSessionProcessor.makeDocument(from: aligned, options: options).render(.init(language: "de", mode: mode))
	}

	func testTriggerAsOwnUtteranceInsertsTheSnippet() {
		XCTAssertEqual(document([("Meine Adresse.", 900, 900)], snippets: [address]), "Alex Example\n123 Example Street\n10115 Berlin")
		XCTAssertEqual(document([("Danke für alles.", 900, 900), ("Grußformel", 900, 900)], snippets: [signoff]),
		               "Danke für alles. Viele Grüße\n\nAlex")
	}

	func testTriggerInsideASentenceStaysText() {
		XCTAssertEqual(document([("Meine Adresse ist neu.", 900, 900)], snippets: [address]), "Meine Adresse ist neu.")
		XCTAssertEqual(document([("meine Adresse", 100, 900)], snippets: [address]), "meine Adresse")
	}

	func testEmptyExamplesAreInactive() {
		let examples = TextSnippet.examples(english: false)
		XCTAssertEqual(examples.map(\.trigger), ["meine Adresse", "meine E-Mail", "Grußformel"])
		XCTAssertTrue(examples.allSatisfy { !$0.isActive })
		XCTAssertEqual(document([("Meine Adresse", 900, 900)], snippets: examples), "Meine Adresse")
	}

	func testPlaceholdersAndLiteralMode() {
		let text = dated.expanded(at: Date(timeIntervalSince1970: 0), language: "de")
		XCTAssertFalse(text.contains("{date}"))
		XCTAssertFalse(text.contains("{time}"))
		XCTAssertTrue(text.hasPrefix("Stand: 01.01.1970"), text)
		// Literal keeps the snippet's own punctuation.
		XCTAssertEqual(document([("Grußformel", 900, 900)], snippets: [signoff], mode: .literal), "Viele Grüße\n\nAlex")
	}

	func testLexiconFileStaysCompatible() throws {
		let old = try JSONDecoder().decode(UserLexicon.self, from: Data(#"{"version":1,"entries":[]}"#.utf8))
		XCTAssertEqual(old.snippets, [])
		XCTAssertFalse(old.snippetExamplesAdded)
		var lexicon = UserLexicon(snippets: [address])
		lexicon.learnedCorrections = [LearnedCorrection(original: "WhisprKit", replacement: "WhisperKit", count: 2)]
		let roundTrip = try JSONDecoder().decode(UserLexicon.self, from: JSONEncoder().encode(lexicon))
		XCTAssertEqual(roundTrip, lexicon)
	}

	func testLearnedCorrectionsCountAndOfferFromTheThreshold() {
		let pair = LearnedCorrection(original: "WhisprKit", replacement: "WhisperKit")
		var counted = LearnedCorrection.counting([pair], into: [])
		XCTAssertEqual(counted.first?.count, 1)
		XCTAssertTrue(LearnedCorrection.offers(counted, threshold: 2).isEmpty)
		counted = LearnedCorrection.counting([pair, LearnedCorrection(original: "x", replacement: "x")], into: counted)
		XCTAssertEqual(counted.count, 1, "identical pairs are not counted")
		XCTAssertEqual(LearnedCorrection.offers(counted, threshold: 2).map(\.replacement), ["WhisperKit"])
		counted[0].declined = true
		XCTAssertTrue(LearnedCorrection.offers(counted, threshold: 1).isEmpty)
		XCTAssertEqual(LearnedCorrection.offers([LearnedCorrection(original: "a", replacement: "b", count: 9)], threshold: 99).count, 1, "threshold is capped at 5")
	}
}
