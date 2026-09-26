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

	func testRequiresUsefulWordTimingCoverageOrRequestsSequentialFallback() {
		let utterances = [Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: Int.max, pauseAfterMs: 600)]
		XCTAssertNil(DictationSessionProcessor.align(EngineResult(text: "ohne Zeiten"), to: utterances))
		let distant = EngineResult(text: "weit", words: [EngineWord(text: "weit", start: 5, end: 5.2)])
		XCTAssertNil(DictationSessionProcessor.align(distant, to: utterances))
	}

	func testEngineCapabilitiesSelectContextPreservingStrategyWhenTimingsExist() {
		let timed = EngineCapabilities(languages: ["de"], supportsAutoLanguage: true, wordTimings: true, tokenConfidences: false, punctuationControl: .stripOnly)
		let untimed = EngineCapabilities(languages: ["de"], supportsAutoLanguage: true, wordTimings: false, tokenConfidences: false, punctuationControl: .stripOnly)
		XCTAssertEqual(DictationSessionProcessor.preferredStrategy(for: timed), .fullRecordingThenAlign)
		XCTAssertEqual(DictationSessionProcessor.preferredStrategy(for: untimed), .transcribeUtterancesSequentially)
	}
}
