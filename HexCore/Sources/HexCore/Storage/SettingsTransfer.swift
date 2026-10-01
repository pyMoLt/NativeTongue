import Foundation

/// One JSON file with the settings and the user lexicon (plan 5.13). Word packs
/// are not included, only their ids (they are large and partly licensed).
public struct SettingsTransfer: Codable, Equatable, Sendable {
	public static let currentVersion = 1

	public var format = "nativetongue-settings"
	public var version = SettingsTransfer.currentVersion
	public var exportedAt: Date
	public var settings: HexSettings
	public var userLexicon: UserLexicon

	public init(settings: HexSettings, userLexicon: UserLexicon, exportedAt: Date = Date()) {
		self.settings = settings
		self.userLexicon = userLexicon
		self.exportedAt = exportedAt
	}

	public func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		return try encoder.encode(self)
	}

	public static func decode(_ data: Data) throws -> SettingsTransfer {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let transfer = try decoder.decode(SettingsTransfer.self, from: data)
		guard transfer.format == "nativetongue-settings", transfer.version <= currentVersion else {
			throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This is not a NativeTongue settings file."])
		}
		return transfer
	}

	/// Settings to apply on import. Machine-specific state (model bootstrap,
	/// storage migration, selected microphone) stays as it is on this Mac.
	public func settingsToApply(onto current: HexSettings) -> HexSettings {
		var result = settings
		result.hasCompletedModelBootstrap = current.hasCompletedModelBootstrap
		result.hasCompletedStorageMigration = current.hasCompletedStorageMigration
		result.hasMigratedLexicon = true
		result.selectedMicrophoneID = current.selectedMicrophoneID
		return result
	}
}

/// Content-free metrics for the optional local diagnostics file (plan 5.13):
/// never text, audio, file names or vocabulary.
public struct DiagnosticsRecord: Codable, Equatable, Sendable {
	public var date: Date
	public var kind: String            // "dictation", "file", "error"
	public var model: String
	public var mode: String
	public var audioSeconds: Double
	public var processingSeconds: Double
	public var utterances: Int
	public var structuralCommands: Int
	public var editCommands: Int
	public var lexiconCorrections: Int
	public var errorCode: String?

	public init(
		date: Date = Date(), kind: String, model: String, mode: String, audioSeconds: Double, processingSeconds: Double,
		utterances: Int = 0, structuralCommands: Int = 0, editCommands: Int = 0, lexiconCorrections: Int = 0, errorCode: String? = nil
	) {
		self.date = date
		self.kind = kind
		self.model = model
		self.mode = mode
		self.audioSeconds = audioSeconds
		self.processingSeconds = processingSeconds
		self.utterances = utterances
		self.structuralCommands = structuralCommands
		self.editCommands = editCommands
		self.lexiconCorrections = lexiconCorrections
		self.errorCode = errorCode
	}

	/// One JSON line.
	public func jsonLine() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		return String(decoding: try encoder.encode(self), as: UTF8.self)
	}

	/// Appends to `url` (JSON Lines), keeping at most `maxLines` recent entries.
	public func append(to url: URL, maxLines: Int = 5_000) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
		lines.append(try jsonLine())
		if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
		try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
	}
}

public extension DictationDocument {
	/// Counts for diagnostics (no content).
	var structuralCommandCount: Int {
		tokens.filter { $0 == .lineBreak || $0 == .paragraphBreak }.count
	}
}
