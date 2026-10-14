import XCTest
@testable import HexCore

/// History trimming hands back removed entries (audio deletion, audit M6) and
/// recordings are owner-only (audit L7).
final class TranscriptHistoryStorageTests: XCTestCase {
	private func transcript(_ text: String) -> Transcript {
		Transcript(timestamp: Date(), text: text, audioPath: URL(fileURLWithPath: "/tmp/\(text).wav"), duration: 1)
	}

	func testInsertNewestTrimsAndReturnsRemovedEntries() {
		var history = TranscriptionHistory(history: [transcript("b"), transcript("a")])
		let removed = history.insertNewest(transcript("c"), limit: 2)
		XCTAssertEqual(history.history.map(\.text), ["c", "b"])
		XCTAssertEqual(removed.map(\.text), ["a"])
	}

	func testInsertNewestWithoutLimitKeepsAll() {
		var history = TranscriptionHistory(history: [transcript("a")])
		XCTAssertTrue(history.insertNewest(transcript("b"), limit: nil).isEmpty)
		XCTAssertTrue(history.insertNewest(transcript("c"), limit: 0).isEmpty)
		XCTAssertEqual(history.history.count, 3)
	}

	func testRecordingsFolderAndFilesAreOwnerOnly() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let folder = root.appendingPathComponent("Recordings", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
		try TranscriptPersistenceClient.prepareRecordingsFolder(folder)
		let folderPermissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
		XCTAssertEqual(folderPermissions, 0o700)
		let file = folder.appendingPathComponent("a.wav")
		try Data([1]).write(to: file)
		TranscriptPersistenceClient.protectRecording(file)
		let filePermissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
		XCTAssertEqual(filePermissions, 0o600)
	}
}
