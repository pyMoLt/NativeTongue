import Foundation
import Hub

/// What a Hugging Face repository offers, read before any download so the
/// user can see size, license and whether the architecture is supported.
public struct LLMRemoteInfo: Sendable, Equatable {
	public let repository: String
	public let revision: String
	public let modelType: String?
	public let license: String?
	public let totalBytes: Int64
	public let hasSafetensors: Bool
	public let isGated: Bool

	public var isSupportedArchitecture: Bool {
		guard let modelType else { return false }
		return LLMModelInstaller.supportedModelTypes.contains(modelType)
	}
}

public enum LLMInstallError: Error, LocalizedError {
	case invalidRepository(String)
	case unsupported(String)
	case server(Int)

	public var errorDescription: String? {
		switch self {
		case let .invalidRepository(text): "“\(text)” is not a Hugging Face model link or ID."
		case let .unsupported(reason): reason
		case let .server(code): "Hugging Face answered with status \(code)."
		}
	}
}

/// Downloads MLX language models only when the user asks for it.
public enum LLMModelInstaller {
	/// Architectures registered in mlx-swift-lm 3.31.4 that make sense for
	/// short text clean-up (V2.5 research R1/R1b).
	public static let supportedModelTypes: Set<String> = [
		"qwen2", "qwen3", "qwen3_5", "qwen3_5_text", "qwen3_moe", "qwen3_5_moe",
		"gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n", "gemma4", "gemma4_text",
		"lfm2", "lfm2_moe", "llama", "mistral", "mistral3", "granite", "granitemoehybrid",
		"phi", "phi3", "smollm3", "olmo2", "olmo3", "exaone4", "apertus", "helium", "cohere",
	]

	/// Files needed to run a model; everything else (images, ONNX, GGUF) is skipped.
	static let fileGlobs = [
		"config.json", "generation_config.json", "*.safetensors", "model.safetensors.index.json",
		"tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "chat_template.jinja",
		"chat_template.json", "tokenizer.model", "vocab.json", "merges.txt", "added_tokens.json",
	]

	/// Accepts "org/name", "https://huggingface.co/org/name" and links to a
	/// file or tree inside the repository.
	public static func repositoryID(from text: String) throws -> String {
		var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if let url = URL(string: value), let host = url.host, host.hasSuffix("huggingface.co") {
			value = url.path
		}
		let parts = value.split(separator: "/").map(String.init).filter { !$0.isEmpty }
		guard parts.count >= 2 else { throw LLMInstallError.invalidRepository(text) }
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
		let id = parts[0] + "/" + parts[1]
		guard parts[0].unicodeScalars.allSatisfy(allowed.contains), parts[1].unicodeScalars.allSatisfy(allowed.contains) else {
			throw LLMInstallError.invalidRepository(text)
		}
		return id
	}

	/// Reads repository metadata (one HTTPS request, no model files).
	public static func remoteInfo(repository: String, revision: String? = nil) async throws -> LLMRemoteInfo {
		let path = revision.map { "\(repository)/revision/\($0)" } ?? repository
		guard let url = URL(string: "https://huggingface.co/api/models/\(path)?blobs=true") else {
			throw LLMInstallError.invalidRepository(repository)
		}
		let (data, response) = try await URLSession.shared.data(from: url)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			throw LLMInstallError.server(http.statusCode)
		}
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		let siblings = json["siblings"] as? [[String: Any]] ?? []
		let names = siblings.compactMap { $0["rfilename"] as? String }
		let needed = siblings.filter { sibling in
			guard let name = sibling["rfilename"] as? String else { return false }
			return fileGlobs.contains { glob in matches(name, glob: glob) }
		}
		let bytes = needed.reduce(Int64(0)) { $0 + ((($1["size"] as? NSNumber)?.int64Value) ?? 0) }
		let config = json["config"] as? [String: Any]
		let card = json["cardData"] as? [String: Any]
		let gated = (json["gated"] as? Bool) ?? ((json["gated"] as? String).map { $0 != "false" } ?? false)
		return LLMRemoteInfo(
			repository: repository,
			revision: (json["sha"] as? String) ?? revision ?? "main",
			modelType: config?["model_type"] as? String,
			license: card?["license"] as? String,
			totalBytes: bytes,
			hasSafetensors: names.contains { $0.hasSuffix(".safetensors") },
			isGated: gated
		)
	}

	/// Downloads `repository` at `revision` below `baseDirectory` and returns
	/// the model folder. Progress is 0…1.
	public static func download(
		repository: String,
		revision: String,
		baseDirectory: URL,
		progress: @escaping @Sendable (Double) -> Void
	) async throws -> URL {
		let hub = HubApi(downloadBase: baseDirectory, useOfflineMode: false)
		return try await hub.snapshot(from: Hub.Repo(id: repository), revision: revision, matching: fileGlobs) { value in
			progress(value.fractionCompleted)
		}
	}

	/// Folder an installed repository lives in (HubApi layout).
	public static func localDirectory(repository: String, baseDirectory: URL) -> URL {
		repository.split(separator: "/").reduce(baseDirectory.appendingPathComponent("models", isDirectory: true)) {
			$0.appendingPathComponent(String($1), isDirectory: true)
		}
	}

	public static func isInstalled(repository: String, baseDirectory: URL) -> Bool {
		let directory = localDirectory(repository: repository, baseDirectory: baseDirectory)
		let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") }
			&& (files.contains("tokenizer.json") || files.contains("tokenizer.model"))
	}

	static func matches(_ name: String, glob: String) -> Bool {
		if glob.hasPrefix("*") { return name.hasSuffix(String(glob.dropFirst())) && !name.contains("/") }
		return name == glob
	}
}
