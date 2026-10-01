import XCTest
@testable import HexCore

final class SettingsTransferTests: XCTestCase {
	func testRoundTripAndMachineStateIsKept() throws {
		var settings = HexSettings()
		settings.dictationMode = .literal
		settings.activeLexiconPacks = ["medical-de"]
		settings.selectedMicrophoneID = "exported-mic"
		let lexicon = UserLexicon(entries: [LexiconEntry(term: "Qwen", lang: "en", category: "user", aliases: ["Gwen"], autoReplace: true)])
		let data = try SettingsTransfer(settings: settings, userLexicon: lexicon).encoded()
		let decoded = try SettingsTransfer.decode(data)
		XCTAssertEqual(decoded.userLexicon, lexicon)
		var current = HexSettings()
		current.selectedMicrophoneID = "this-mac"
		current.hasCompletedModelBootstrap = true
		let applied = decoded.settingsToApply(onto: current)
		XCTAssertEqual(applied.dictationMode, .literal)
		XCTAssertEqual(applied.activeLexiconPacks, ["medical-de"])
		XCTAssertEqual(applied.selectedMicrophoneID, "this-mac")
		XCTAssertTrue(applied.hasCompletedModelBootstrap)
		XCTAssertThrowsError(try SettingsTransfer.decode(Data(#"{"format":"other","version":1}"#.utf8)))
	}

	func testDiagnosticsLinesContainNoContentAndAreBounded() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString).jsonl")
		defer { try? FileManager.default.removeItem(at: url) }
		for index in 0..<5 {
			try DiagnosticsRecord(kind: "dictation", model: "m", mode: "literal", audioSeconds: Double(index), processingSeconds: 1).append(to: url, maxLines: 3)
		}
		let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
		XCTAssertEqual(lines.count, 3)
		XCTAssertTrue(lines.last!.contains("\"audioSeconds\":4"))
		XCTAssertFalse(lines.last!.contains("text"))
	}
}
