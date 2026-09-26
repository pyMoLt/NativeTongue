import Foundation

public enum LocalASRBackend: String, Codable, Equatable, Sendable {
	case whisperKitCoreML
	case parakeetFluidAudioCoreML
	case qwen3MLX
	case canaryFluidAudioCoreML
	case omiMedicalParakeetCoreML

	public var displayName: String {
		switch self {
		case .whisperKitCoreML: "WhisperKit / Core ML"
		case .parakeetFluidAudioCoreML: "FluidAudio / Core ML"
		case .qwen3MLX: "Qwen3-ASR / MLX"
		case .canaryFluidAudioCoreML: "Canary / Core ML"
		case .omiMedicalParakeetCoreML: "Omi Med STT / Core ML"
		}
	}
}

public struct LocalASRModelCapabilities: Codable, Equatable, Sendable {
	public let wordTimings: Bool
	public let contextPrompt: Bool
	public let languageHint: Bool
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

	public var id: String { internalName }
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
