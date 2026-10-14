import Foundation

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var text: String
    public var audioPath: URL
    public var duration: TimeInterval
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    
    public init(
        id: UUID = UUID(),
        timestamp: Date,
        text: String,
        audioPath: URL,
        duration: TimeInterval,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.audioPath = audioPath
        self.duration = duration
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
    }
}

public struct TranscriptionHistory: Codable, Equatable, Sendable {
    public var history: [Transcript] = []
    
    public init(history: [Transcript] = []) {
        self.history = history
    }

    /// Inserts the newest entry and trims to `limit` (nil or ≤ 0: no limit).
    /// Returns the removed entries; their audio must be deleted by the caller.
    @discardableResult
    public mutating func insertNewest(_ transcript: Transcript, limit: Int?) -> [Transcript] {
        history.insert(transcript, at: 0)
        guard let limit, limit > 0, history.count > limit else { return [] }
        let removed = Array(history[limit...])
        history.removeSubrange(limit...)
        return removed
    }
}
