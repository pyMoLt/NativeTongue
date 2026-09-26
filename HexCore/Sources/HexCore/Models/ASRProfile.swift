import Foundation

/// A consciously selected dictation domain. Profiles never route audio
/// automatically; they only remember a model and provide a bounded terminology
/// hint when the chosen backend supports decoder context.
public enum ASRProfile: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
	case general
	case medical
	case technical

	public var displayName: String {
		switch self {
		case .general: "General"
		case .medical: "Medical"
		case .technical: "Technical"
		}
	}

	/// A deliberately small starter list. It is decoder context, not a
	/// dictionary and not a promise that the ASR will emit every spelling.
	public var starterTerms: [String] {
		switch self {
		case .general:
			[]
		case .medical:
			[
				"Ileum", "Ilium", "Jejunum", "Duodenum", "Nävus", "Nervus",
				"Myokardinfarkt", "ST-Hebungsinfarkt", "Clopidogrel", "Apixaban",
				"Pembrolizumab", "Urothelkarzinom", "Mycophenolatmofetil",
				"Musculus vastus lateralis",
			]
		case .technical:
			[
				"Swift", "SwiftUI", "Core ML", "MLX", "WhisperKit", "FluidAudio",
				"PyTorch", "NumPy", "FastAPI", "PostgreSQL", "OpenAI", "Qwen",
				"Voxtral", "Parakeet",
			]
		}
	}
}

public enum ASRTerminologyContext {
	public static let maximumTerms = 64
	public static let maximumCharacters = 800

	/// Builds a conservative, bounded prompt from starter terms and the user's
	/// newline/comma/semicolon-separated additions. Duplicates are removed while
	/// preserving order. Huge medical libraries are intentionally not injected
	/// into a decoder prompt because every supported backend has a finite context.
	public static func prompt(profile: ASRProfile, additionalTerms: String) -> String? {
		let prefix = "Expected terminology: "
		let separators = CharacterSet(charactersIn: ",;\n\r")
		let custom = additionalTerms
			.components(separatedBy: separators)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }

		var seen = Set<String>()
		var accepted: [String] = []
		for term in profile.starterTerms + custom {
			let key = term.folding(
				options: [.caseInsensitive, .diacriticInsensitive],
				locale: Locale(identifier: "en_US_POSIX")
			)
			guard seen.insert(key).inserted else { continue }
			let candidate = (accepted + [term]).joined(separator: ", ")
			guard accepted.count < maximumTerms, prefix.count + candidate.count <= maximumCharacters else { break }
			accepted.append(term)
		}

		guard !accepted.isEmpty else { return nil }
		return prefix + accepted.joined(separator: ", ")
	}
}
