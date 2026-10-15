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
	/// Core AI (macOS 27, experimental): Parakeet Ultra streaming bundle via Apple's CoreAISpeech.
	case parakeetCoreAI
	/// Core AI (macOS 27, experimental): Qwen3-ASR 1.7B via the vendored coreai-kit runtime.
	case qwen3CoreAI
	/// Streaming-only engines (V2.5).
	case nemotronStreamingCoreML
	case voxtralRealtimeMLX

	public var displayName: String {
		switch self {
		case .whisperKitCoreML: "WhisperKit / Core ML"
		case .parakeetFluidAudioCoreML: "FluidAudio / Core ML"
		case .qwen3MLX: "Qwen3-ASR / MLX"
		case .canaryFluidAudioCoreML: "Canary / Core ML"
		case .omiMedicalParakeetCoreML: "Omi Med STT / Core ML"
		case .cohereMLX: "Cohere Transcribe / MLX"
		case .appleSpeechAnalyzer: "Apple SpeechAnalyzer (on-device)"
		case .parakeetCoreAI: "Parakeet / Core AI (macOS 27)"
		case .qwen3CoreAI: "Qwen3-ASR / Core AI (macOS 27)"
		case .nemotronStreamingCoreML: "Nemotron Streaming / Core ML"
		case .voxtralRealtimeMLX: "Voxtral Realtime / MLX"
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

/// How a model can drive Streaming mode: `native` engines emit text while you
/// speak; `emulated` engines insert one block after each speech pause.
public enum LocalASRStreamingSupport: String, Codable, Equatable, Sendable {
	case native, emulated, none
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
	public let streaming: LocalASRStreamingSupport
	public let recommendedForStreaming: Bool
	/// Only usable in Streaming mode (no batch transcription).
	public let streamingOnly: Bool
	/// Two friendly sentences for the model card ("what is it good for").
	public let blurb: String?
	/// Oldest macOS that can run the model ("27.0" for Core AI); nil = the app's base.
	public let minimumOS: String?
	/// Short measurement summary for models outside the benchmark table (model-benchmarks.json).
	public let measured: String?

	/// False for Core AI models on macOS 26: the card shows them as unavailable.
	public var isSupportedOnThisMac: Bool {
		guard let minimumOS else { return true }
		let parts = minimumOS.split(separator: ".").compactMap { Int($0) }
		let required = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.dropFirst().first ?? 0, patchVersion: 0)
		return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
	}

	public var id: String { internalName }
	public var engineCapabilities: EngineCapabilities { capabilities.engineCapabilities(languages: languages) }

	private enum CodingKeys: String, CodingKey {
		case displayName, internalName, backend, repository, revision, precision, license
		case languages, size, storageSize, capabilities, experimental, group, literalRating, recommendedFor
		case streaming, recommendedForStreaming, blurb, streamingOnly, minimumOS, measured
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
		streaming = try values.decodeIfPresent(LocalASRStreamingSupport.self, forKey: .streaming) ?? .none
		recommendedForStreaming = try values.decodeIfPresent(Bool.self, forKey: .recommendedForStreaming) ?? false
		blurb = try values.decodeIfPresent(String.self, forKey: .blurb)
		streamingOnly = try values.decodeIfPresent(Bool.self, forKey: .streamingOnly) ?? false
		minimumOS = try values.decodeIfPresent(String.self, forKey: .minimumOS)
		measured = try values.decodeIfPresent(String.self, forKey: .measured)
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

	/// Parsed once; the catalog is a bundled, immutable resource.
	static let bundled: [LocalASRModelDescriptor] = (try? load()) ?? []

	static func descriptor(named name: String, bundle: Bundle = .main) throws -> LocalASRModelDescriptor {
		let descriptors = bundle == .main && !bundled.isEmpty ? bundled : try load(bundle: bundle)
		guard let descriptor = descriptors.first(where: { $0.internalName == name }) else {
			throw NSError(domain: "LocalASRModelCatalog", code: 2, userInfo: [
				NSLocalizedDescriptionKey: "Unsupported local model identifier: \(name)",
			])
		}
		return descriptor
	}
}
