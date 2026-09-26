import Foundation
import HexCore

public enum LocalASRBackend: String, Codable, Equatable, Sendable {
	case whisperKitCoreML
	case parakeetFluidAudioCoreML
	case qwen3MLX
	case canaryFluidAudioCoreML
	case omiMedicalParakeetCoreML
	case cohereMLX
	case appleSpeechAnalyzer

	public var displayName: String {
		switch self {
		case .whisperKitCoreML: "WhisperKit / Core ML"
		case .parakeetFluidAudioCoreML: "FluidAudio / Core ML"
		case .qwen3MLX: "Qwen3-ASR / MLX"
		case .canaryFluidAudioCoreML: "Canary / Core ML"
		case .omiMedicalParakeetCoreML: "Omi Med STT / Core ML"
		case .cohereMLX: "Cohere Transcribe / MLX"
		case .appleSpeechAnalyzer: "Apple SpeechAnalyzer (on-device)"
		}
	}
}

public struct LocalASRModelCapabilities: Codable, Equatable, Sendable {
	public let wordTimings: Bool
	public let contextPrompt: Bool
	public let languageHint: Bool
	public let supportsAutoLanguage: Bool
	public let tokenConfidences: Bool
	public let punctuationControl: PunctuationControl
	public let biasing: [BiasingKind]
	public let maxWindowSeconds: Double?
	public let diarization: Bool

	private enum CodingKeys: String, CodingKey {
		case wordTimings, contextPrompt, languageHint, supportsAutoLanguage
		case tokenConfidences, punctuationControl, biasing, maxWindowSeconds, diarization
	}

	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		wordTimings = try values.decode(Bool.self, forKey: .wordTimings)
		contextPrompt = try values.decode(Bool.self, forKey: .contextPrompt)
		languageHint = try values.decode(Bool.self, forKey: .languageHint)
		supportsAutoLanguage = try values.decodeIfPresent(Bool.self, forKey: .supportsAutoLanguage) ?? false
		tokenConfidences = try values.decodeIfPresent(Bool.self, forKey: .tokenConfidences) ?? false
		punctuationControl = try values.decodeIfPresent(PunctuationControl.self, forKey: .punctuationControl) ?? .stripOnly
		biasing = try values.decodeIfPresent([BiasingKind].self, forKey: .biasing) ?? []
		maxWindowSeconds = try values.decodeIfPresent(Double.self, forKey: .maxWindowSeconds)
		diarization = try values.decodeIfPresent(Bool.self, forKey: .diarization) ?? false
	}

	public func engineCapabilities(languages: [String]) -> EngineCapabilities {
		EngineCapabilities(
			languages: languages,
			supportsAutoLanguage: supportsAutoLanguage,
			wordTimings: wordTimings,
			tokenConfidences: tokenConfidences,
			punctuationControl: punctuationControl,
			biasing: biasing,
			maxWindowSeconds: maxWindowSeconds,
			diarization: diarization
		)
	}
}

public enum LocalASRModelGroup: String, Codable, Equatable, Sendable {
	case recommended, general, medical, experimental
}

public enum LocalASRLiteralRating: String, Codable, Equatable, Sendable {
	case reliable, limited, unverified, unsuitable
}

public struct LocalASRModelDescriptor: Codable, Equatable, Identifiable, Sendable {
	public let displayName: String
	public let internalName: String
	public let backend: LocalASRBackend
	public let repository: String
	public let revision: String?
	public let precision: String
	public let license: String
	public let languages: [String]
	public let size: String
	public let storageSize: String
	public let capabilities: LocalASRModelCapabilities
	public let experimental: Bool
	public let group: LocalASRModelGroup
	public let literalRating: LocalASRLiteralRating
	public let recommendedFor: [DictationMode]

	public var id: String { internalName }
	public var engineCapabilities: EngineCapabilities { capabilities.engineCapabilities(languages: languages) }

	private enum CodingKeys: String, CodingKey {
		case displayName, internalName, backend, repository, revision, precision, license
		case languages, size, storageSize, capabilities, experimental, group, literalRating, recommendedFor
	}

	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		displayName = try values.decode(String.self, forKey: .displayName)
		internalName = try values.decode(String.self, forKey: .internalName)
		backend = try values.decode(LocalASRBackend.self, forKey: .backend)
		repository = try values.decode(String.self, forKey: .repository)
		revision = try values.decodeIfPresent(String.self, forKey: .revision)
		precision = try values.decode(String.self, forKey: .precision)
		license = try values.decode(String.self, forKey: .license)
		languages = try values.decode([String].self, forKey: .languages)
		size = try values.decode(String.self, forKey: .size)
		storageSize = try values.decode(String.self, forKey: .storageSize)
		capabilities = try values.decode(LocalASRModelCapabilities.self, forKey: .capabilities)
		experimental = try values.decode(Bool.self, forKey: .experimental)
		group = try values.decodeIfPresent(LocalASRModelGroup.self, forKey: .group) ?? (experimental ? .experimental : .general)
		literalRating = try values.decodeIfPresent(LocalASRLiteralRating.self, forKey: .literalRating) ?? .unverified
		recommendedFor = try values.decodeIfPresent([DictationMode].self, forKey: .recommendedFor) ?? []
	}
}

enum LocalASRModelCatalog {
	static func decode(_ data: Data) throws -> [LocalASRModelDescriptor] {
		try JSONDecoder().decode([LocalASRModelDescriptor].self, from: data)
	}

	static func load(bundle: Bundle = .main) throws -> [LocalASRModelDescriptor] {
		guard let url = bundle.url(forResource: "models", withExtension: "json") ??
			bundle.url(forResource: "models", withExtension: "json", subdirectory: "Data")
		else {
			throw NSError(domain: "LocalASRModelCatalog", code: 1, userInfo: [
				NSLocalizedDescriptionKey: "The bundled local model catalog is missing.",
			])
		}
		return try decode(Data(contentsOf: url))
	}

	static func descriptor(named name: String, bundle: Bundle = .main) throws -> LocalASRModelDescriptor {
		guard let descriptor = try load(bundle: bundle).first(where: { $0.internalName == name }) else {
			throw NSError(domain: "LocalASRModelCatalog", code: 2, userInfo: [
				NSLocalizedDescriptionKey: "Unsupported local model identifier: \(name)",
			])
		}
		return descriptor
	}
}
