import Foundation

/// Known Parakeet Core ML bundles that Hex supports.
public enum ParakeetModel: String, CaseIterable, Sendable {
	case englishV2 = "parakeet-tdt-0.6b-v2-coreml"
	case multilingualV3 = "parakeet-tdt-0.6b-v3-coreml"
	case multilingualUltra = "parakeet-ultra-coreml"

	/// The identifier used throughout the app (matches the on-disk folder name).
	public var identifier: String { rawValue }

	/// Whether the model only supports English transcription.
	public var isEnglishOnly: Bool {
		self == .englishV2
	}

	/// Exact repository used by FluidAudio for explicit installation.
	public var repository: String {
		switch self {
		case .englishV2: "FluidInference/parakeet-tdt-0.6b-v2-coreml"
		case .multilingualV3: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
		case .multilingualUltra: "FluidInference/parakeet-ultra-coreml"
		}
	}

	/// Immutable Hugging Face revision enforced through FluidAudio's registry override.
	public var revision: String {
		switch self {
		case .englishV2: "ee09c569f73759e6d44c9bd16766f477b2b36d39"
		case .multilingualV3: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
		case .multilingualUltra: "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
		}
	}

	/// Short capability label for UI copy.
	public var capabilityLabel: String {
		isEnglishOnly ? "English" : "Multilingual"
	}

	/// Convenience text for recommendation badges.
	public var recommendationLabel: String {
		switch self {
		case .englishV2: "English reference"
		case .multilingualV3: "Multilingual reference"
		case .multilingualUltra: "Experimental quality candidate"
		}
	}
}
