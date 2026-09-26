import XCTest
@testable import HexCore

final class DictationSessionProcessorTests: XCTestCase {
	func testFullRecordingWordTimingsAlignAcrossAudioPauseBoundaries() throws {
		let utterances = [
			Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: Int.max, pauseAfterMs: 600),
			Utterance(id: 1, range: 20_800..<36_800, pauseBeforeMs: 600, pauseAfterMs: 700),
			Utterance(id: 2, range: 42_400..<58_400, pauseBeforeMs: 700, pauseAfterMs: Int.max),
		]
		let result = EngineResult(text: "Erster Abschnitt neuer Absatz Zweiter Abschnitt", words: [
			EngineWord(text: "Erster", start: 0.1, end: 0.3),
			EngineWord(text: "Abschnitt", start: 0.4, end: 0.8),
			EngineWord(text: "neuer", start: 1.35, end: 1.55),
			EngineWord(text: "Absatz", start: 1.55, end: 1.8),
			EngineWord(text: "Zweiter", start: 2.7, end: 3.0),
			EngineWord(text: "Abschnitt", start: 3.0, end: 3.3),
		])

		let aligned = try XCTUnwrap(DictationSessionProcessor.align(result, to: utterances))
		XCTAssertEqual(aligned.map { $0.text }, ["Erster Abschnitt", "neuer Absatz", "Zweiter Abschnitt"])
		let document = DictationSessionProcessor.makeDocument(
			from: aligned,
			options: .init(mode: .literal, formatNumbers: false)
		)
		XCTAssertEqual(document.render(.init(language: "de", mode: .literal)), "Erster Abschnitt\n\nZweiter Abschnitt")
	}

	func testPunctuationCommandsRenderAfterTimedAlignment() throws {
		let utterances = [Utterance(id: 0, range: 0..<48_000, pauseBeforeMs: Int.max, pauseAfterMs: Int.max)]
		let result = EngineResult(text: "Status Doppelpunkt Alpha Komma Beta", words: [
			EngineWord(text: "Status", start: 0.1, end: 0.35),
			EngineWord(text: "Doppelpunkt", start: 0.4, end: 0.8),
			EngineWord(text: "Alpha", start: 1.0, end: 1.2),
			EngineWord(text: "Komma", start: 1.3, end: 1.55),
			EngineWord(text: "Beta", start: 1.6, end: 1.8),
		])

		let aligned = try XCTUnwrap(DictationSessionProcessor.align(result, to: utterances))
		let document = DictationSessionProcessor.makeDocument(
			from: aligned,
			options: .init(mode: .literal, formatNumbers: false)
		)
		XCTAssertEqual(document.render(.init(language: "de", mode: .literal)), "Status: Alpha, Beta")
	}

	func testEditCommandAppliesToPreviousUtteranceBeforeInsertion() throws {
		let utterances = [
			AlignedUtterance(utterance: Utterance(id: 0, range: 0..<1, pauseBeforeMs: Int.max, pauseAfterMs: 600), text: "Satz eins"),
			AlignedUtterance(utterance: Utterance(id: 1, range: 2..<3, pauseBeforeMs: 600, pauseAfterMs: 600), text: "streich das"),
			AlignedUtterance(utterance: Utterance(id: 2, range: 4..<5, pauseBeforeMs: 600, pauseAfterMs: Int.max), text: "Satz zwei"),
		]
		let document = DictationSessionProcessor.makeDocument(from: utterances, options: .init(mode: .normal, formatNumbers: false))
		XCTAssertEqual(document.render(.init(mode: .normal)), "Satz zwei")
	}

	func testRequiresWordTimingsOrRequestsSequentialFallback() {
		let utterances = [Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: Int.max, pauseAfterMs: 600)]
		XCTAssertNil(DictationSessionProcessor.align(EngineResult(text: "ohne Zeiten"), to: utterances))
		let untimed = EngineResult(text: "a b c", words: [
			EngineWord(text: "a", start: .nan, end: .nan),
			EngineWord(text: "b", start: .nan, end: .nan),
			EngineWord(text: "c", start: 0.1, end: 0.2),
		])
		XCTAssertNil(DictationSessionProcessor.align(untimed, to: utterances))
	}

	func testAlignmentNeverDropsWords() throws {
		let utterances = [
			Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: Int.max, pauseAfterMs: 3_000),
			Utterance(id: 1, range: 64_000..<80_000, pauseBeforeMs: 3_000, pauseAfterMs: Int.max),
		]
		let result = EngineResult(text: "eins leise zwei drei vier", words: [
			EngineWord(text: "eins", start: 0.2, end: 0.5),
			EngineWord(text: "leise", start: 2.0, end: 2.3),      // far from both utterances
			EngineWord(text: "zwei", start: .nan, end: .nan),     // no timing: follows predecessor
			EngineWord(text: "drei", start: 4.1, end: 4.4),
			EngineWord(text: "vier", start: 9.0, end: 9.3),       // after the last utterance
		])
		let aligned = try XCTUnwrap(DictationSessionProcessor.align(result, to: utterances))
		XCTAssertEqual(aligned.map(\.text), ["eins leise zwei", "drei vier"])
		XCTAssertEqual(aligned.map(\.text).joined(separator: " ").split(separator: " ").count, 5)
	}

	func testEngineCapabilitiesSelectContextPreservingStrategyWhenTimingsExist() {
		let timed = EngineCapabilities(languages: ["de"], supportsAutoLanguage: true, wordTimings: true, tokenConfidences: false, punctuationControl: .stripOnly)
		let untimed = EngineCapabilities(languages: ["de"], supportsAutoLanguage: true, wordTimings: false, tokenConfidences: false, punctuationControl: .stripOnly)
		XCTAssertEqual(DictationSessionProcessor.preferredStrategy(for: timed), .fullRecordingThenAlign)
		XCTAssertEqual(DictationSessionProcessor.preferredStrategy(for: untimed), .transcribeUtterancesSequentially)
	}

	func testShortHallucinationUtteranceIsDropped() {
		let utterances = [
			AlignedUtterance(utterance: Utterance(id: 0, range: 0..<48_000, pauseBeforeMs: Int.max, pauseAfterMs: 900), text: "Befund unauffällig"),
			AlignedUtterance(utterance: Utterance(id: 1, range: 62_400..<76_800, pauseBeforeMs: 900, pauseAfterMs: Int.max), text: "Vielen Dank."),
		]
		let document = DictationSessionProcessor.makeDocument(from: utterances, options: .init(mode: .normal, formatNumbers: false))
		XCTAssertEqual(document.render(.init(mode: .normal)), "Befund unauffällig")
	}
}
