import Dependencies
import Foundation

public struct TranscriptPersistenceClient: Sendable {
    public var save: @Sendable (
        _ result: String,
        _ audioURL: URL,
        _ duration: TimeInterval,
        _ sourceAppBundleID: String?,
        _ sourceAppName: String?
    ) async throws -> Transcript
    
    public var deleteAudio: @Sendable (_ transcript: Transcript) async throws -> Void
}

extension TranscriptPersistenceClient: DependencyKey {
    public static let liveValue: TranscriptPersistenceClient = {
        return TranscriptPersistenceClient(
            save: { result, audioURL, duration, sourceAppBundleID, sourceAppName in
                let fm = FileManager.default
                let recordingsFolder = try URL.hexApplicationSupport.appendingPathComponent("Recordings", isDirectory: true)
                try TranscriptPersistenceClient.prepareRecordingsFolder(recordingsFolder)
                
                let filename = "\(Date().timeIntervalSince1970)-\(UUID().uuidString).wav"
                let finalURL = recordingsFolder.appendingPathComponent(filename)
                try fm.copyItem(at: audioURL, to: finalURL)
                TranscriptPersistenceClient.protectRecording(finalURL)
                
                return Transcript(
                    timestamp: Date(),
                    text: result,
                    audioPath: finalURL,
                    duration: duration,
                    sourceAppBundleID: sourceAppBundleID,
                    sourceAppName: sourceAppName
                )
            },
            deleteAudio: { transcript in
                FileManager.default.removeItemIfExists(at: transcript.audioPath)
            }
        )
    }()
    
    public static let testValue = TranscriptPersistenceClient(
        save: { _, _, _, _, _ in
            Transcript(timestamp: Date(), text: "", audioPath: URL(fileURLWithPath: "/"), duration: 0)
        },
        deleteAudio: { _ in }
    )
}

extension TranscriptPersistenceClient {
    /// Owner-only folder like `recovery/` (audit L7).
    public static func prepareRecordingsFolder(_ folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// Owner-only file; data protection where the volume supports it.
    public static func protectRecording(_ file: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
    }
}

public extension DependencyValues {
    var transcriptPersistence: TranscriptPersistenceClient {
        get { self[TranscriptPersistenceClient.self] }
        set { self[TranscriptPersistenceClient.self] = newValue }
    }
}
