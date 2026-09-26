import AudioCommon
import CohereTranscribeASR
import Foundation
import HexCore
import Hub

/// Cohere Transcribe 2B via the vendored MLX runtime (replaces the Core ML export,
/// which needed ~7.9 GB RSS and lost text at chunk seams in the benchmark).
actor CohereMLXASRClient {
	static let modelName = "cohere-transcribe-2b-8bit-mlx"
	static let repository = "aufklarer/Cohere-Transcribe-2B-MLX-8bit"
	static let revision = "924ad09b5bc13619c16248d2c6b625b430e9e192"
	static let requiredFiles = [
		"config.json", "generation_config.json", "preprocessor_config.json", "model.safetensors",
		"model.safetensors.index.json", "tokenizer.model", "tokenizer_config.json", "special_tokens_map.json",
	]
	static let supportedLanguages = ["en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko"]
	private static let manifestName = "local-asr-installation.json"

	private struct Manifest: Codable, Equatable {
		let repository: String
		let revision: String
		let weightBytes: UInt64
	}

	private var model: CohereTranscribeModel?
	private let logger = HexLog.models

	static func downloadBase() throws -> URL {
		try URL.hexModelsDirectory.appendingPathComponent("cohere-mlx", isDirectory: true)
	}

	static func modelDirectory() throws -> URL {
		repository.split(separator: "/").reduce(try downloadBase().appendingPathComponent("models", isDirectory: true)) {
			$0.appendingPathComponent(String($1), isDirectory: true)
		}
	}

	func isInstalled() -> Bool {
		guard let directory = try? Self.modelDirectory(),
		      let data = try? Data(contentsOf: directory.appendingPathComponent(Self.manifestName)),
		      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
		      manifest.repository == Self.repository, manifest.revision == Self.revision
		else { return false }
		let weights = directory.appendingPathComponent("model.safetensors")
		let size = (try? weights.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
		return size == manifest.weightBytes
			&& Self.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
	}

	/// Explicit install action only.
	func install(progress: @escaping (Progress) -> Void) async throws {
		if isInstalled() { return }
		let hub = HubApi(downloadBase: try Self.downloadBase(), useOfflineMode: false)
		let directory = try await hub.snapshot(
			from: HubApi.Repo(id: Self.repository),
			revision: Self.revision,
			matching: Self.requiredFiles
		) { value in
			let mapped = Progress(totalUnitCount: 100)
			mapped.completedUnitCount = Int64(value.fractionCompleted * 95)
			progress(mapped)
		}
		guard Self.requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
			throw NSError(domain: "CohereMLX", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Cohere download is incomplete."])
		}
		let size = try directory.appendingPathComponent("model.safetensors").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
		let manifest = Manifest(repository: Self.repository, revision: Self.revision, weightBytes: UInt64(size))
		try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
		let done = Progress(totalUnitCount: 100)
		done.completedUnitCount = 100
		progress(done)
	}

	func load() throws {
		guard model == nil else { return }
		guard isInstalled() else {
			throw NSError(domain: "CohereMLX", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cohere Transcribe (MLX) is not installed."])
		}
		model = try CohereTranscribeModel.fromDirectory(try Self.modelDirectory())
		logger.info("Loaded Cohere Transcribe MLX 8-bit")
	}

	func unload() {
		model = nil
	}

	func delete() throws {
		unload()
		let base = try Self.downloadBase()
		if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
	}

	/// Cohere needs an explicit language (no auto-detect); default German.
	func transcribe(samples: [Float], options: RequestOptions) throws -> EngineResult {
		try load()
		guard let model else { throw NSError(domain: "CohereMLX", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cohere is not loaded."]) }
		let language = options.language.flatMap { Self.supportedLanguages.contains($0) ? $0 : nil } ?? "de"
		let text = model.transcribe(audio: samples, sampleRate: 16_000, language: language)
		return EngineResult(text: text, detectedLanguage: language)
	}
}
