import Foundation

public struct RecoveredRecording: Sendable, Equatable, Identifiable {
	public let url: URL
	public let createdAt: Date

	public var id: URL { url }

	public init(url: URL, createdAt: Date) {
		self.url = url
		self.createdAt = createdAt
	}
}

/// Stores in-progress recordings outside the system temporary directory so an app
/// crash does not silently destroy the audio needed to recover a dictation.
public struct RecordingRecoveryStore: Sendable {
	public static let retention: TimeInterval = 7 * 24 * 60 * 60

	public let directoryURL: URL

	public init(directoryURL: URL? = nil) throws {
		if let directoryURL {
			self.directoryURL = directoryURL.standardizedFileURL
		} else {
			self.directoryURL = try URL.hexApplicationSupport
				.appendingPathComponent("recovery", isDirectory: true)
		}
	}

	@discardableResult
	public func makeCaptureURL() throws -> URL {
		try prepareDirectory()
		return directoryURL.appendingPathComponent("capture-\(UUID().uuidString).wav")
	}

	/// Returns active recovery WAVs newest-first and removes entries older than seven days.
	public func pendingRecordings(now: Date = Date()) throws -> [RecoveredRecording] {
		try prepareDirectory()
		let fileManager = FileManager.default
		let urls = try fileManager.contentsOfDirectory(
			at: directoryURL,
			includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
			options: [.skipsHiddenFiles]
		)
		let cutoff = now.addingTimeInterval(-Self.retention)
		var pending: [RecoveredRecording] = []

		for url in urls where isManagedRecordingURL(url) {
			let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
			guard values.isRegularFile == true else { continue }
			let modifiedAt = values.contentModificationDate ?? .distantPast
			if modifiedAt < cutoff {
				try fileManager.removeItem(at: url)
				continue
			}
			pending.append(RecoveredRecording(url: url, createdAt: modifiedAt))
		}

		return pending.sorted { $0.createdAt > $1.createdAt }
	}

	public func remove(_ recording: RecoveredRecording) throws {
		guard isManagedRecordingURL(recording.url) else {
			throw RecordingRecoveryError.notManagedRecording
		}
		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: recording.url.path) {
			try fileManager.removeItem(at: recording.url)
		}
	}

	private func prepareDirectory() throws {
		let fileManager = FileManager.default
		try fileManager.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
	}

	private func isManagedRecordingURL(_ url: URL) -> Bool {
		let candidate = url.standardizedFileURL
		return candidate.deletingLastPathComponent() == directoryURL
			&& candidate.lastPathComponent.hasPrefix("capture-")
			&& candidate.pathExtension.lowercased() == "wav"
	}
}

public enum RecordingRecoveryError: Error, Equatable {
	case notManagedRecording
}
