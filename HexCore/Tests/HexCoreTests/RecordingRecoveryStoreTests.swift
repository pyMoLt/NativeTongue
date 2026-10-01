import Foundation
import XCTest
@testable import HexCore

final class RecordingRecoveryStoreTests: XCTestCase {
	func testCaptureURLsUsePrivateRecoveryDirectory() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalASR-RecoveryTests-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = try RecordingRecoveryStore(directoryURL: directory)
		let captureURL = try store.makeCaptureURL()
		let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)

		XCTAssertEqual(captureURL.deletingLastPathComponent(), directory.standardizedFileURL)
		XCTAssertTrue(captureURL.lastPathComponent.hasPrefix("capture-"))
		XCTAssertEqual(captureURL.pathExtension, "wav")
		XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
	}

	func testPendingRecordingsAreNewestFirstAndExpiredFilesAreRemoved() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalASR-RecoveryTests-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = try RecordingRecoveryStore(directoryURL: directory)
		let newestURL = try store.makeCaptureURL()
		let olderURL = try store.makeCaptureURL()
		let expiredURL = try store.makeCaptureURL()
		for url in [newestURL, olderURL, expiredURL] {
			XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([0x00])))
		}

		let now = Date()
		try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: newestURL.path)
		try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: olderURL.path)
		try FileManager.default.setAttributes(
			[.modificationDate: now.addingTimeInterval(-RecordingRecoveryStore.retention - 1)],
			ofItemAtPath: expiredURL.path
		)

		let pending = try store.pendingRecordings(now: now)

		XCTAssertEqual(
			pending.map { $0.url.standardizedFileURL },
			[newestURL, olderURL].map(\.standardizedFileURL)
		)
		XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path))
	}

	func testRemoveRejectsFilesOutsideRecoveryDirectory() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalASR-RecoveryTests-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = try RecordingRecoveryStore(directoryURL: directory)
		let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent("capture-outside.wav")

		XCTAssertThrowsError(try store.remove(RecoveredRecording(url: outsideURL, createdAt: Date()))) { error in
			XCTAssertEqual(error as? RecordingRecoveryError, .notManagedRecording)
		}
	}
}
