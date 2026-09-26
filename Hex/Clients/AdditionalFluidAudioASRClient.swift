import Foundation
import CryptoKit
import HexCore
import Hub

#if canImport(FluidAudio)
import FluidAudio

enum OmiMedicalInstallationValidator {
	struct Manifest: Codable, Equatable {
		let formatVersion: Int
		let repository: String
		let revision: String
		let weightSHA256: [String: String]
		let runtime: String
	}

	static let modelName = "omi-med-stt-v1-en-fp16-coreml"
	static let repository = "cmsha/omi-med-stt-v1-coreml"
	static let revision = "81533058ad87d18d3461e21595963edd2d517741"
	static let runtimeRevision = "FluidAudio-0.17.4"
	static let requiredComponents = [
		"Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
		"JointDecision.mlmodelc", "parakeet_vocab.json",
	]
	static let requiredDownloadGlobs = [
		"Preprocessor.mlmodelc/*", "Preprocessor.mlmodelc/weights/*",
		"Encoder.mlmodelc/*", "Encoder.mlmodelc/weights/*",
		"Decoder.mlmodelc/*", "Decoder.mlmodelc/weights/*",
		"JointDecision.mlmodelc/*", "JointDecision.mlmodelc/weights/*",
		"parakeet_vocab.json",
	]
	static let weightSHA256 = [
		"Preprocessor.mlmodelc/weights/weight.bin": "88ac21314df88dcd368d910a94ea06c0e10d689086c98ecaf81057cea8b50e04",
		"Encoder.mlmodelc/weights/weight.bin": "6ffe21826a7891f4c0100033197687050d7750bfb181d852a07786c5db9cf205",
		"Decoder.mlmodelc/weights/weight.bin": "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba",
		"JointDecision.mlmodelc/weights/weight.bin": "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d",
	]
	private static let manifestName = ".local-asr-omi-med-installation.json"

	static func isInstalled(at directory: URL) -> Bool {
		guard let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent(manifestName))) else {
			return false
		}
		return manifest == expectedManifest && containsRequiredComponents(at: directory)
	}

	static func containsRequiredComponents(at directory: URL) -> Bool {
		let fileManager = FileManager.default
		for name in requiredComponents {
			let url = directory.appendingPathComponent(name)
			var isDirectory: ObjCBool = false
			guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
			if name.hasSuffix(".mlmodelc") {
				guard isDirectory.boolValue,
				      let children = try? fileManager.contentsOfDirectory(atPath: url.path),
				      !children.isEmpty else { return false }
			} else {
				guard !isDirectory.boolValue,
				      let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
				      (values.fileSize ?? 0) > 0 else { return false }
			}
		}
		return weightSHA256.keys.allSatisfy { relativePath in
			let url = directory.appendingPathComponent(relativePath)
			return fileManager.fileExists(atPath: url.path)
		}
	}

	static func verifyPinnedWeights(at directory: URL) throws {
		for (relativePath, expectedHash) in weightSHA256 {
			let url = directory.appendingPathComponent(relativePath)
			guard try Self.sha256(of: url) == expectedHash else {
				throw installationError("Omi Med STT weight checksum failed for \(relativePath).")
			}
		}
	}

	static func createManifest(at directory: URL) throws {
		guard containsRequiredComponents(at: directory) else {
			throw installationError("The Omi download is missing required FluidAudio Core ML components.")
		}
		let data = try JSONEncoder().encode(expectedManifest)
		try data.write(to: directory.appendingPathComponent(manifestName), options: .atomic)
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

	static func modelDirectory() throws -> URL {
		try URL.hexModelsDirectory.appendingPathComponent(modelName, isDirectory: true)
	}

	private static var expectedManifest: Manifest {
		Manifest(
			formatVersion: 1,
			repository: repository,
			revision: revision,
			weightSHA256: weightSHA256,
			runtime: runtimeRevision
		)
	}

	private static func installationError(_ description: String) -> NSError {
		NSError(domain: "OmiMedInstallation", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
	}
}

/// Canary and the English medical Parakeet adapter (Omi) kept separate from the
/// standard Parakeet client because their prompts and artifact layouts differ.
actor AdditionalFluidAudioASRClient {
	private let logger = HexLog.parakeet
	private var canaryModels: CanaryModels?
	private var medicalParakeetManager: AsrManager?
	private var loadedModelName: String?

	private let canaryName = "canary-1b-v2-int4-coreml"
	private let canaryRevision = "a5567919114916212fadc1c9b80c168095b14ae2"

	init() {
		var revisions = ModelRegistry.revisionOverrides
		revisions[Repo.canary1bV2.remotePath] = canaryRevision
		ModelRegistry.revisionOverrides = revisions
		ModelHub.offlineMode = true
	}

	func isModelAvailable(_ descriptor: LocalASRModelDescriptor) -> Bool {
		if descriptor.backend == .omiMedicalParakeetCoreML,
		   descriptor.internalName == OmiMedicalInstallationValidator.modelName,
		   let directory = try? OmiMedicalInstallationValidator.modelDirectory() {
			return OmiMedicalInstallationValidator.isInstalled(at: directory)
		}
		guard let directory = try? modelDirectory(for: descriptor) else { return false }
		switch descriptor.internalName {
		case canaryName:
			return CanaryModels.modelsExist(at: directory, precision: .int4)
		default:
			return false
		}
	}

	/// This is the only method in this adapter allowed to access the model hub.
	/// It is called only by the explicit Models → Download UI action.
	func ensureLoaded(_ descriptor: LocalASRModelDescriptor, progress: @escaping (Progress) -> Void) async throws {
		guard isSupported(descriptor) else { throw unsupportedModel(descriptor.internalName) }
		if loadedModelName == descriptor.internalName,
		   canaryModels != nil || medicalParakeetManager != nil {
			progress(Self.completedProgress())
			return
		}
		unload()
		if Self.isMedicalParakeet(descriptor) {
			try await installMedicalParakeet(descriptor, progress: progress)
			try loadMedicalParakeet(descriptor)
			loadedModelName = descriptor.internalName
			progress(Self.completedProgress())
			return
		}
		let previousOfflineMode = ModelHub.offlineMode
		ModelHub.offlineMode = false
		defer { ModelHub.offlineMode = previousOfflineMode }

		let directory = try modelDirectory(for: descriptor)
		switch descriptor.internalName {
		case canaryName:
			if !CanaryModels.modelsExist(at: directory, precision: .int4) {
				_ = try await CanaryModels.download(precision: .int4) { value in
					progress(Self.mapProgress(value.fractionCompleted))
				}
			}
			try loadCanary(from: directory)
		default:
			throw unsupportedModel(descriptor.internalName)
		}
		loadedModelName = descriptor.internalName
		progress(Self.completedProgress())
	}

	/// The inference path is intentionally local-only and fails closed when any
	/// required model component is missing.
	func loadInstalled(_ descriptor: LocalASRModelDescriptor, progress: @escaping (Progress) -> Void) async throws {
		guard isSupported(descriptor) else { throw unsupportedModel(descriptor.internalName) }
		guard isModelAvailable(descriptor) else {
			throw NSError(domain: "LocalASR", code: -20, userInfo: [
				NSLocalizedDescriptionKey: "This model is not completely installed. Use Download in Model Settings first.",
			])
		}
		if loadedModelName == descriptor.internalName,
		   canaryModels != nil || medicalParakeetManager != nil {
			progress(Self.completedProgress())
			return
		}
		unload()
		ModelHub.offlineMode = true
		progress(Progress(totalUnitCount: 100))
		if Self.isMedicalParakeet(descriptor) {
			try loadMedicalParakeet(descriptor)
			loadedModelName = descriptor.internalName
			progress(Self.completedProgress())
			return
		}
		let directory = try modelDirectory(for: descriptor)
		switch descriptor.internalName {
		case canaryName:
			try loadCanary(from: directory)
		default:
			throw unsupportedModel(descriptor.internalName)
		}
		loadedModelName = descriptor.internalName
		progress(Self.completedProgress())
	}

	func transcribe(
		_ descriptor: LocalASRModelDescriptor,
		url: URL,
		language: String?
	) async throws -> TranscriptionOutput {
		try validateLanguage(descriptor, language: language)
		guard loadedModelName == descriptor.internalName else {
			throw NSError(domain: "LocalASR", code: -21, userInfo: [
				NSLocalizedDescriptionKey: "The selected local model is not loaded.",
			])
		}
		switch descriptor.internalName {
		case OmiMedicalInstallationValidator.modelName:
			guard let medicalParakeetManager else { throw modelNotLoaded(descriptor.displayName) }
			var decoderState = TdtDecoderState.make(decoderLayers: await medicalParakeetManager.decoderLayerCount)
			let result = try await medicalParakeetManager.transcribe(url, decoderState: &decoderState, language: .english)
			let timings = buildWordTimings(from: result.tokenTimings ?? []).map {
				TranscriptWordTiming(word: $0.word, startTime: $0.startTime, endTime: $0.endTime)
			}
			return TranscriptionOutput(text: result.text, wordTimings: timings)
		case canaryName:
			guard let canaryModels else { throw modelNotLoaded(descriptor.displayName) }
			let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(url)
			guard !samples.isEmpty else { return TranscriptionOutput(text: "", wordTimings: []) }
			let prompt = try CanaryPromptFactory.prompt(language: language, vocabulary: canaryModels.tokenizer.vocabulary)
			let manager = CanaryManager(models: canaryModels, prompt: prompt)
			let text = try await manager.transcribe(audio: samples)
			return TranscriptionOutput(text: text, wordTimings: [])
		default:
			throw unsupportedModel(descriptor.internalName)
		}
	}

	func deleteModel(_ descriptor: LocalASRModelDescriptor) throws {
		guard isSupported(descriptor) else { throw unsupportedModel(descriptor.internalName) }
		if loadedModelName == descriptor.internalName { unload() }
		if Self.isMedicalParakeet(descriptor) {
			let directory = try Self.medicalParakeetDirectory(for: descriptor)
			if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
			return
		}
		let directory = try modelDirectory(for: descriptor)
		if FileManager.default.fileExists(atPath: directory.path) {
			try FileManager.default.removeItem(at: directory)
		}
	}

	func unload() {
		canaryModels = nil
		medicalParakeetManager = nil
		loadedModelName = nil
	}

	func validateLanguage(_ descriptor: LocalASRModelDescriptor, language: String?) throws {
		switch descriptor.backend {
		case .canaryFluidAudioCoreML:
			guard language.map({ ["en", "de", "fr", "es"].contains($0.lowercased()) }) == true else {
				throw languageRequired(descriptor.displayName, supported: ["en", "de", "fr", "es"])
			}
		case .omiMedicalParakeetCoreML:
			guard language?.lowercased() == "en" else {
				throw languageRequired(descriptor.displayName, supported: ["en"])
			}
		default:
			break
		}
	}

	private func loadCanary(from directory: URL) throws {
		guard CanaryModels.modelsExist(at: directory, precision: .int4) else {
			throw modelFilesMissing("Canary-1B-v2 int4")
		}
		canaryModels = try CanaryModels.load(from: directory, precision: .int4)
	}

	private func installMedicalParakeet(
		_ descriptor: LocalASRModelDescriptor,
		progress: @escaping (Progress) -> Void
	) async throws {
		switch descriptor.internalName {
		case OmiMedicalInstallationValidator.modelName:
			try await installOmiMedical(descriptor, progress: progress)
		default:
			throw unsupportedModel(descriptor.internalName)
		}
	}

	private func installOmiMedical(
		_ descriptor: LocalASRModelDescriptor,
		progress: @escaping (Progress) -> Void
	) async throws {
		guard descriptor.backend == .omiMedicalParakeetCoreML,
		      descriptor.internalName == OmiMedicalInstallationValidator.modelName,
		      descriptor.repository == OmiMedicalInstallationValidator.repository,
		      descriptor.revision == OmiMedicalInstallationValidator.revision else {
			throw unsupportedModel(descriptor.internalName)
		}
		if isModelAvailable(descriptor) { return }
		let root = try URL.hexModelsDirectory
		let hubDirectory = root.appendingPathComponent("omi-med-hub-download", isDirectory: true)
		try FileManager.default.createDirectory(at: hubDirectory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: hubDirectory) }
		let hub = HubApi(downloadBase: hubDirectory, useOfflineMode: false)
		let repo = HubApi.Repo(id: OmiMedicalInstallationValidator.repository)
		let repoDirectory = try await hub.snapshot(
			from: repo,
			revision: OmiMedicalInstallationValidator.revision,
			matching: OmiMedicalInstallationValidator.requiredDownloadGlobs
		) { value in
			let mapped = Progress(totalUnitCount: 100)
			mapped.completedUnitCount = Int64(value.fractionCompleted * 72)
			progress(mapped)
		}
		guard !Task.isCancelled else { throw CancellationError() }
		let target = try OmiMedicalInstallationValidator.modelDirectory()
		guard !FileManager.default.fileExists(atPath: target.path) else {
			throw installationError("An incomplete Omi Med STT installation already exists. Delete it in Model Settings before retrying.")
		}
		let staging = target.deletingLastPathComponent().appendingPathComponent(".omi-med-stage-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: staging) }
		for name in OmiMedicalInstallationValidator.requiredComponents {
			let source = repoDirectory.appendingPathComponent(name)
			guard FileManager.default.fileExists(atPath: source.path) else {
				throw installationError("Omi Med STT download is missing \(name).")
			}
			try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent(name))
		}
		guard !Task.isCancelled else { throw CancellationError() }
		try OmiMedicalInstallationValidator.verifyPinnedWeights(at: staging)
		try OmiMedicalInstallationValidator.createManifest(at: staging)
		try FileManager.default.moveItem(at: staging, to: target)
		progress(Self.completedProgress())
	}

	private func loadMedicalParakeet(_ descriptor: LocalASRModelDescriptor) throws {
		let directory = try Self.medicalParakeetDirectory(for: descriptor)
		guard isSupported(descriptor) else { throw unsupportedModel(descriptor.internalName) }
		let models: AsrModels
		switch descriptor.internalName {
		case OmiMedicalInstallationValidator.modelName:
			guard OmiMedicalInstallationValidator.isInstalled(at: directory) else {
				throw modelFilesMissing("Omi Med STT English medical FP16")
			}
			models = try AsrModels.loadLocal(from: directory, version: .v2)
		default:
			throw unsupportedModel(descriptor.internalName)
		}
		medicalParakeetManager = AsrManager(config: .default, models: models)
	}

	private func modelDirectory(for descriptor: LocalASRModelDescriptor) throws -> URL {
		let root = try Self.modelsRootDirectory()
		switch descriptor.internalName {
		case canaryName:
			return root.appendingPathComponent(Repo.canary1bV2.folderName, isDirectory: true)
		default:
			throw unsupportedModel(descriptor.internalName)
		}
	}

	private func isSupported(_ descriptor: LocalASRModelDescriptor) -> Bool {
		(descriptor.backend == .canaryFluidAudioCoreML && descriptor.internalName == canaryName)
			|| (descriptor.backend == .omiMedicalParakeetCoreML && descriptor.internalName == OmiMedicalInstallationValidator.modelName)
	}

	private static func isMedicalParakeet(_ descriptor: LocalASRModelDescriptor) -> Bool {
		(descriptor.backend == .omiMedicalParakeetCoreML && descriptor.internalName == OmiMedicalInstallationValidator.modelName)
	}

	private static func medicalParakeetDirectory(for descriptor: LocalASRModelDescriptor) throws -> URL {
		switch descriptor.internalName {
		case OmiMedicalInstallationValidator.modelName where descriptor.backend == .omiMedicalParakeetCoreML:
			try OmiMedicalInstallationValidator.modelDirectory()
		default:
			throw NSError(domain: "LocalASR", code: -24, userInfo: [NSLocalizedDescriptionKey: "Unsupported FluidAudio model: \(descriptor.internalName)"])
		}
	}

	private func installationError(_ description: String) -> NSError {
		NSError(domain: "LocalASRInstallation", code: 2, userInfo: [NSLocalizedDescriptionKey: description])
	}

	private static func modelsRootDirectory() throws -> URL {
		guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
			throw NSError(domain: "LocalASR", code: -22, userInfo: [NSLocalizedDescriptionKey: "Application Support is unavailable."])
		}
		return support.appendingPathComponent("FluidAudio/Models", isDirectory: true)
	}

	private static func mapProgress(_ fraction: Double) -> Progress {
		let progress = Progress(totalUnitCount: 100)
		progress.completedUnitCount = Int64(max(0, min(1, fraction)) * 100)
		return progress
	}

	private static func completedProgress() -> Progress {
		mapProgress(1)
	}

	private func languageRequired(_ name: String, supported: [String]) -> NSError {
		NSError(domain: "LocalASR", code: -23, userInfo: [
			NSLocalizedDescriptionKey: "\(name) needs a language selection (\(supported.joined(separator: ", "))). Set German or English under Language settings, or select Whisper/Qwen for automatic language detection.",
		])
	}

	private func unsupportedModel(_ name: String) -> NSError {
		NSError(domain: "LocalASR", code: -24, userInfo: [NSLocalizedDescriptionKey: "Unsupported FluidAudio model: \(name)"])
	}

	private func modelNotLoaded(_ name: String) -> NSError {
		NSError(domain: "LocalASR", code: -25, userInfo: [NSLocalizedDescriptionKey: "\(name) is not loaded."])
	}

	private func modelFilesMissing(_ name: String) -> NSError {
		NSError(domain: "LocalASR", code: -26, userInfo: [NSLocalizedDescriptionKey: "Required local model files for \(name) are missing."])
	}
}

enum CanaryPromptFactory {
	static func prompt(language: String?, vocabulary: [Int: String]) throws -> [Int32] {
		guard let code = language?.lowercased(), ["en", "de", "fr", "es"].contains(code) else {
			throw NSError(domain: "Canary", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Canary requires an explicit English, German, French, or Spanish language selection.",
			])
		}
		let required = ["▁", "<|startofcontext|>", "<|startoftranscript|>", "<|emo:undefined|>", "<|\(code)|>", "<|pnc|>", "<|noitn|>", "<|notimestamp|>", "<|nodiarize|>"]
		var ids: [String: Int32] = [:]
		for token in required {
			guard let id = vocabulary.first(where: { $0.value == token })?.key,
			      let narrowID = Int32(exactly: id) else {
				throw NSError(domain: "Canary", code: -2, userInfo: [
					NSLocalizedDescriptionKey: "Canary tokenizer is missing required prompt token \(token).",
				])
			}
			ids[token] = narrowID
		}
		let languageToken = "<|\(code)|>"
		return [
			ids["▁"]!, ids["<|startofcontext|>"]!, ids["<|startoftranscript|>"]!, ids["<|emo:undefined|>"]!,
			ids[languageToken]!, ids[languageToken]!, ids["<|pnc|>"]!, ids["<|noitn|>"]!,
			ids["<|notimestamp|>"]!, ids["<|nodiarize|>"]!,
		]
	}
}

#else

actor AdditionalFluidAudioASRClient {
	func isModelAvailable(_ descriptor: LocalASRModelDescriptor) -> Bool { false }
	func validateLanguage(_ descriptor: LocalASRModelDescriptor, language: String?) throws {
		throw NSError(domain: "LocalASR", code: -30, userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not linked."])
	}
	func ensureLoaded(_ descriptor: LocalASRModelDescriptor, progress: @escaping (Progress) -> Void) async throws {
		throw NSError(domain: "LocalASR", code: -30, userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not linked."])
	}
	func loadInstalled(_ descriptor: LocalASRModelDescriptor, progress: @escaping (Progress) -> Void) async throws {
		throw NSError(domain: "LocalASR", code: -30, userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not linked."])
	}
	func transcribe(_ descriptor: LocalASRModelDescriptor, url: URL, language: String?) async throws -> TranscriptionOutput {
		throw NSError(domain: "LocalASR", code: -30, userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not linked."])
	}
	func deleteModel(_ descriptor: LocalASRModelDescriptor) throws {}
	func unload() {}
}

#endif
