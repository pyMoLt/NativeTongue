import AudioCommon
import CryptoKit
import Foundation
import HexCore
import Hub
import Qwen3ASR

private let qwenRuntimeSourceCommit = "c1aa219bc2284239ff6917d675a3e1978c840260"
private let qwenManifestFileName = "local-asr-installation.json"

struct QwenInstallationManifest: Codable, Equatable, Sendable {
	struct FileRecord: Codable, Equatable, Sendable {
		let path: String
		let size: UInt64
		let sha256: String
	}

	let formatVersion: Int
	let repository: String
	let revision: String
	let runtimeSourceCommit: String
	let files: [FileRecord]
}

enum QwenInstallationValidator {
	static let requiredMetadataFiles = [
		"config.json", "vocab.json", "merges.txt", "tokenizer_config.json",
	]

	static func requiredFiles(in directory: URL) throws -> [URL] {
		let fileManager = FileManager.default
		var files: [URL] = []
		for name in requiredMetadataFiles {
			let url = directory.appendingPathComponent(name)
			guard fileManager.fileExists(atPath: url.path) else {
				throw validationError("Missing required Qwen file: \(name)")
			}
			files.append(url)
		}

		let contents = try fileManager.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
			options: [.skipsHiddenFiles]
		)
		let weights = contents
			.filter { $0.pathExtension == "safetensors" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
		guard !weights.isEmpty else {
			throw validationError("No Qwen safetensors weights were found.")
		}
		files.append(contentsOf: weights)

		let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
		if fileManager.fileExists(atPath: indexURL.path) {
			let data = try Data(contentsOf: indexURL)
			guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			      let weightMap = root["weight_map"] as? [String: String]
			else {
				throw validationError("The Qwen safetensors index is malformed.")
			}
			for shard in Set(weightMap.values) {
				guard !shard.contains(".."), !shard.hasPrefix("/") else {
					throw validationError("The Qwen index contains an unsafe shard path.")
				}
				let shardURL = directory.appendingPathComponent(shard)
				guard fileManager.fileExists(atPath: shardURL.path) else {
					throw validationError("Missing Qwen weight shard: \(shard)")
				}
			}
			files.append(indexURL)
		}

		for file in files {
			let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
			guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
				throw validationError("Qwen file is empty or not a regular file: \(file.lastPathComponent)")
			}
		}
		return files
	}

	static func quickValidate(
		directory: URL,
		repository: String,
		revision: String
	) throws -> QwenInstallationManifest {
		_ = try requiredFiles(in: directory)
		let manifestURL = directory.appendingPathComponent(qwenManifestFileName)
		let manifest = try JSONDecoder().decode(
			QwenInstallationManifest.self,
			from: Data(contentsOf: manifestURL)
		)
		guard manifest.formatVersion == 1,
		      manifest.repository == repository,
		      manifest.revision == revision,
		      manifest.runtimeSourceCommit == qwenRuntimeSourceCommit,
		      !manifest.files.isEmpty
		else {
			throw validationError("The Qwen installation manifest does not match this catalog entry.")
		}
		return manifest
	}

	static func createManifest(
		directory: URL,
		repository: String,
		revision: String
	) throws -> QwenInstallationManifest {
		let files = try requiredFiles(in: directory)
		let records = try files.map { file -> QwenInstallationManifest.FileRecord in
			let values = try file.resourceValues(forKeys: [.fileSizeKey])
			return .init(
				path: file.lastPathComponent,
				size: UInt64(values.fileSize ?? 0),
				sha256: try sha256(of: file)
			)
		}
		let manifest = QwenInstallationManifest(
			formatVersion: 1,
			repository: repository,
			revision: revision,
			runtimeSourceCommit: qwenRuntimeSourceCommit,
			files: records.sorted { $0.path < $1.path }
		)
		let data = try JSONEncoder.prettyPrinted.encode(manifest)
		try data.write(to: directory.appendingPathComponent(qwenManifestFileName), options: .atomic)
		return manifest
	}

	static func strictValidate(
		directory: URL,
		repository: String,
		revision: String
	) throws {
		let manifest = try quickValidate(directory: directory, repository: repository, revision: revision)
		let requiredNames = Set(try requiredFiles(in: directory).map(\.lastPathComponent))
		let recordedNames = Set(manifest.files.map(\.path))
		guard requiredNames == recordedNames else {
			throw validationError("The Qwen installation file set changed after download.")
		}

		for record in manifest.files {
			guard !record.path.contains(".."), !record.path.contains("/") else {
				throw validationError("The Qwen manifest contains an unsafe file path.")
			}
			let file = directory.appendingPathComponent(record.path)
			let values = try file.resourceValues(forKeys: [.fileSizeKey])
			guard UInt64(values.fileSize ?? 0) == record.size,
			      try sha256(of: file) == record.sha256
			else {
				throw validationError("Qwen file integrity check failed: \(record.path)")
			}
		}
	}

	static func sha256(of url: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher = SHA256()
		while true {
			let data = try handle.read(upToCount: 1_048_576) ?? Data()
			if data.isEmpty { break }
			hasher.update(data: data)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	private static func validationError(_ description: String) -> NSError {
		NSError(domain: "QwenInstallation", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
	}
}

actor QwenASRClient {
	private var model: Qwen3ASRModel?
	private var loadedModelName: String?
	private var integrityValidated = Set<String>()

	func isModelAvailable(_ descriptor: LocalASRModelDescriptor) -> Bool {
		guard descriptor.backend == .qwen3MLX, let revision = descriptor.revision else { return false }
		do {
			_ = try QwenInstallationValidator.quickValidate(
				directory: modelDirectory(for: descriptor),
				repository: descriptor.repository,
				revision: revision
			)
			return true
		} catch {
			return false
		}
	}

	func ensureLoaded(
		_ descriptor: LocalASRModelDescriptor,
		progress: @escaping (Progress) -> Void
	) async throws {
		guard descriptor.backend == .qwen3MLX, let revision = descriptor.revision else {
			throw unsupportedModel(descriptor.internalName)
		}
		if loadedModelName == descriptor.internalName, model != nil {
			progress(completedProgress())
			return
		}

		let root = try qwenRootDirectory()
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let hub = HubApi(downloadBase: root, useOfflineMode: false)
		let repo = HubApi.Repo(id: descriptor.repository)
		let directory = try await hub.snapshot(
			from: repo,
			revision: revision,
			matching: [
				"config.json", "*.safetensors", "model.safetensors.index.json",
				"vocab.json", "merges.txt", "tokenizer_config.json",
				"generation_config.json", "preprocessor_config.json", "chat_template.json",
			]
		) { hubProgress in
			let mapped = Progress(totalUnitCount: 100)
			mapped.completedUnitCount = Int64(hubProgress.fractionCompleted * 75)
			progress(mapped)
		}
		_ = try QwenInstallationValidator.createManifest(
			directory: directory,
			repository: descriptor.repository,
			revision: revision
		)
		integrityValidated.remove(descriptor.internalName)
		try await loadInstalled(descriptor, progress: progress)
	}

	func loadInstalled(
		_ descriptor: LocalASRModelDescriptor,
		progress: @escaping (Progress) -> Void
	) async throws {
		guard descriptor.backend == .qwen3MLX, let revision = descriptor.revision else {
			throw unsupportedModel(descriptor.internalName)
		}
		if loadedModelName == descriptor.internalName, model != nil {
			progress(completedProgress())
			return
		}

		let directory = modelDirectory(for: descriptor)
		if !integrityValidated.contains(descriptor.internalName) {
			try QwenInstallationValidator.strictValidate(
				directory: directory,
				repository: descriptor.repository,
				revision: revision
			)
			integrityValidated.insert(descriptor.internalName)
		}

		unload()
		model = try await Qwen3ASRModel.fromPretrained(
			modelId: descriptor.repository,
			cacheDir: directory,
			offlineMode: true
		) { fraction, _ in
			let mapped = Progress(totalUnitCount: 100)
			mapped.completedUnitCount = 75 + Int64(fraction * 25)
			progress(mapped)
		}
		loadedModelName = descriptor.internalName
		// At most 1 GB MLX scratch cache instead of the library's 4 GB: the decoder
		// working set is far smaller; measured peak was 8.6 GB with the default.
		// Never raises the app policy (512 MB, `MLXMemoryPolicy`).
		MLXMemoryControl.capCacheLimit(1 << 30)
		progress(completedProgress())
	}

	func transcribe(
		_ url: URL,
		language: String?,
		context: String?
	) throws -> TranscriptionOutput {
		guard let model else {
			throw NSError(domain: "QwenASR", code: 2, userInfo: [
				NSLocalizedDescriptionKey: "Qwen3-ASR is not loaded.",
			])
		}
		let samples = try AudioFileLoader.load(url: url, targetSampleRate: 16_000)
		guard !samples.isEmpty else {
			return TranscriptionOutput(text: "", wordTimings: [])
		}

		let chunkSize = 28 * 16_000
		var chunks: [[Float]] = []
		chunks.reserveCapacity(max(1, Int(ceil(Double(samples.count) / Double(chunkSize)))))
		for start in stride(from: 0, to: samples.count, by: chunkSize) {
			chunks.append(Array(samples[start..<min(start + chunkSize, samples.count)]))
		}
		let options = Qwen3DecodingOptions(language: language, context: context)
		let texts = chunks.map { model.transcribe(audio: $0, sampleRate: 16_000, options: options) }
		return TranscriptionOutput(
			text: texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
				.joined(separator: " "),
			wordTimings: []
		)
	}

	/// Cached per loaded model: token IDs that decode to pure punctuation.
	private var punctuationIDs: Set<Int32>?

	/// Samples-based transcription for one utterance.
	/// - Literal mode masks punctuation tokens in the decoder.
	/// - Optional context biasing (experimental) is guarded against the model
	///   copying the bias list into the transcript; on a leak the utterance is
	///   decoded again without context.
	func transcribe(samples: [Float], options: RequestOptions) throws -> EngineResult {
		guard let model else {
			throw NSError(domain: "QwenASR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Qwen3-ASR is not loaded."])
		}
		guard !samples.isEmpty else { return EngineResult(text: "") }
		var decoding = Qwen3DecodingOptions(language: options.language)
		// Repeated phrases ("neuer Absatz" twice) are legitimate in dictation.
		decoding.longInputThresholdSeconds = .infinity
		if options.punctuation == .suppressed {
			if punctuationIDs == nil { punctuationIDs = model.punctuationTokenIDs() }
			decoding.suppressedTokenIDs = punctuationIDs ?? []
		}
		func run(context: String?) -> String {
			var withContext = decoding
			withContext.context = context
			return model.transcribe(audio: samples, sampleRate: 16_000, options: withContext)
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		let terms = Array(options.biasTerms.prefix(50))
		var text = run(context: terms.isEmpty ? nil : terms.joined(separator: ", "))
		if !terms.isEmpty, BiasLeakGuard.leakedRange(in: text, biasTerms: terms) != nil {
			HexLog.transcription.notice("Qwen3-ASR context leak detected; re-decoding without context")
			text = run(context: nil)
		}
		return EngineResult(
			text: text,
			detectedLanguage: options.language,
			punctuationWasSuppressed: options.punctuation == .suppressed
		)
	}

	func deleteModel(_ descriptor: LocalASRModelDescriptor) throws {
		if loadedModelName == descriptor.internalName { unload() }
		integrityValidated.remove(descriptor.internalName)
		let directory = modelDirectory(for: descriptor)
		if FileManager.default.fileExists(atPath: directory.path) {
			try FileManager.default.removeItem(at: directory)
		}
	}

	func unload() {
		punctuationIDs = nil
		model?.unload()
		model = nil
		loadedModelName = nil
		// Without this, ~2.5 GB of MLX buffers stayed resident after unloading.
		MLXMemoryControl.clearCache()
	}

	func modelDirectory(for descriptor: LocalASRModelDescriptor) -> URL {
		let root = (try? qwenRootDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
		return HubApi(downloadBase: root, useOfflineMode: true)
			.localRepoLocation(HubApi.Repo(id: descriptor.repository))
	}

	private func qwenRootDirectory() throws -> URL {
		try URL.hexModelsDirectory.appendingPathComponent("qwen3-mlx", isDirectory: true)
	}

	private func completedProgress() -> Progress {
		let progress = Progress(totalUnitCount: 100)
		progress.completedUnitCount = 100
		return progress
	}

	private func unsupportedModel(_ name: String) -> NSError {
		NSError(domain: "QwenASR", code: 1, userInfo: [
			NSLocalizedDescriptionKey: "Unsupported Qwen3-ASR catalog entry: \(name)",
		])
	}
}

private extension JSONEncoder {
	static var prettyPrinted: JSONEncoder {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return encoder
	}
}
