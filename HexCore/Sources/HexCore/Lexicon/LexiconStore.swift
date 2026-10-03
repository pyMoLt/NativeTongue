import Foundation

/// Files of the lexicon under `Application Support/<bundle>/lexicon/`:
/// `user.json` (user lexicon) and `packs/<id>.json` (imported word packs).
/// Packs are never bundled with the app (GPL parts, BfArM terms).
public struct LexiconStore: Sendable {
	public let directory: URL

	public init(directory: URL) {
		self.directory = directory
	}

	public static func defaultStore() throws -> LexiconStore {
		LexiconStore(directory: try URL.hexApplicationSupport.appendingPathComponent("lexicon", isDirectory: true))
	}

	public var userURL: URL { directory.appendingPathComponent("user.json") }
	public var packsDirectory: URL { directory.appendingPathComponent("packs", isDirectory: true) }

	// MARK: User lexicon

	public func loadUser() throws -> UserLexicon {
		guard FileManager.default.fileExists(atPath: userURL.path) else { return UserLexicon() }
		return try JSONDecoder().decode(UserLexicon.self, from: Data(contentsOf: userURL))
	}

	public func saveUser(_ lexicon: UserLexicon) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		// "Until first user authentication": readable while the screen is locked
		// (full protection made reads and writes fail with EPERM after locking).
		try encoder.encode(lexicon).write(to: userURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
	}

	// MARK: Packs

	public func installedPacks() -> [LexiconPackInfo] {
		guard let files = try? FileManager.default.contentsOfDirectory(at: packsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
			return []
		}
		return files.filter { $0.pathExtension == "json" }.compactMap { url in
			guard let header = try? Self.readHeader(url) else { return nil }
			let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
			return LexiconPackInfo(id: header.id, version: header.version, license: header.license, entryCount: header.entryCount ?? 0, fileBytes: size)
		}.sorted { $0.id < $1.id }
	}

	public func loadPack(id: String) throws -> LexiconPack {
		try JSONDecoder().decode(LexiconPack.self, from: Data(contentsOf: packURL(id: id)))
	}

	/// Validates and copies a pack file; returns its metadata.
	@discardableResult
	public func importPack(from source: URL) throws -> LexiconPackInfo {
		let data = try Data(contentsOf: source)
		let pack = try JSONDecoder().decode(LexiconPack.self, from: data)
		guard Self.isValidPackID(pack.id), !pack.entries.isEmpty else {
			throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The file is not a Local ASR word pack."])
		}
		try FileManager.default.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
		try data.write(to: packURL(id: pack.id), options: .atomic)
		return LexiconPackInfo(id: pack.id, version: pack.version, license: pack.license, entryCount: pack.entries.count, fileBytes: data.count)
	}

	public func removePack(id: String) throws {
		let url = packURL(id: id)
		if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
	}

	private func packURL(id: String) -> URL {
		packsDirectory.appendingPathComponent("\(id).json")
	}

	static func isValidPackID(_ id: String) -> Bool {
		!id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
	}

	fileprivate struct Header: Decodable {
		let id: String
		let version: String?
		let license: String?
		let entryCount: Int?

		enum CodingKeys: String, CodingKey { case id, version, license, entryCount }

		init(from decoder: Decoder) throws {
			let values = try decoder.container(keyedBy: CodingKeys.self)
			id = try values.decode(String.self, forKey: .id)
			version = (try? values.decodeIfPresent(String.self, forKey: .version))
				?? (try? values.decodeIfPresent(Int.self, forKey: .version)).flatMap { $0.map(String.init) }
			license = try? values.decodeIfPresent(String.self, forKey: .license)
			entryCount = try? values.decodeIfPresent(Int.self, forKey: .entryCount)
		}
	}

	/// Reads only the metadata; falls back to a full decode for packs without `entryCount`.
	private static func readHeader(_ url: URL) throws -> Header {
		let data = try Data(contentsOf: url, options: .mappedIfSafe)
		let header = try JSONDecoder().decode(Header.self, from: data)
		guard header.entryCount == nil else { return header }
		let pack = try JSONDecoder().decode(LexiconPack.self, from: data)
		return Header(id: pack.id, version: pack.version, license: pack.license, entryCount: pack.entries.count)
	}
}

private extension LexiconStore.Header {
	init(id: String, version: String?, license: String?, entryCount: Int?) {
		self.id = id
		self.version = version
		self.license = license
		self.entryCount = entryCount
	}
}

// MARK: - Migration of V1 settings (plan 5.12)

public enum LexiconMigration {
	/// Vocabulary lines become user entries of their profile; word remappings
	/// become aliases (match → replacement). Existing entries are kept.
	public static func migrate(_ settings: HexSettings, into lexicon: UserLexicon) -> UserLexicon {
		var result = lexicon
		var known = Set(result.entries.map { LexiconIndex.normalize($0.term) })
		func add(_ entry: LexiconEntry) {
			let key = LexiconIndex.normalize(entry.term)
			if let existing = result.entries.firstIndex(where: { LexiconIndex.normalize($0.term) == key }) {
				for alias in entry.aliases where !result.entries[existing].aliases.contains(alias) {
					result.entries[existing].aliases.append(alias)
				}
				return
			}
			guard known.insert(key).inserted else { return }
			result.entries.append(entry)
		}
		let vocabularies: [(ASRProfile, String)] = [
			(.general, settings.generalVocabulary),
			(.medical, settings.medicalVocabulary),
			(.technical, settings.technicalVocabulary),
		]
		for (profile, text) in vocabularies {
			for term in terms(in: text) {
				add(LexiconEntry(term: term, lang: "de", category: "user", caseSensitive: true, autoReplace: true, profile: profile))
			}
		}
		for remapping in settings.wordRemappings where remapping.isEnabled {
			let match = remapping.match.trimmingCharacters(in: .whitespacesAndNewlines)
			let replacement = remapping.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !match.isEmpty, !replacement.isEmpty, match.lowercased() != replacement.lowercased() else { continue }
			add(LexiconEntry(term: replacement, lang: "de", category: "user", aliases: [match], caseSensitive: true, autoReplace: true))
		}
		return result
	}

	public static func terms(in text: String) -> [String] {
		text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;")))
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}
}
