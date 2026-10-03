import Foundation
import MLX
import MLXLLM
import MLXLMCommon

public enum LocalLLMError: Error, LocalizedError {
	case notLoaded
	case missingWeights(URL)

	public var errorDescription: String? {
		switch self {
		case .notLoaded: "No AI post-processing model is loaded."
		case let .missingWeights(url): "The AI model files are missing in \(url.lastPathComponent)."
		}
	}
}

/// Runs one small instruction-tuned MLX language model on this Mac.
///
/// Holds at most one model. Generation is greedy (temperature 0) and never
/// uses the network: weights and tokenizer come from an installed folder.
public actor LocalLLMEngine {
	public static let shared = LocalLLMEngine()

	private var container: ModelContainer?
	public private(set) var loadedDirectory: URL?

	public init() {}

	public var isLoaded: Bool { container != nil }

	/// Loads the model in `directory` unless it is already loaded.
	public func load(directory: URL) async throws {
		if container != nil, loadedDirectory == directory { return }
		unload()
		let config = directory.appendingPathComponent("config.json")
		guard FileManager.default.fileExists(atPath: config.path) else {
			throw LocalLLMError.missingWeights(directory)
		}
		container = try await loadModelContainer(from: directory, using: LocalTokenizerLoader())
		loadedDirectory = directory
	}

	public func unload() {
		container = nil
		loadedDirectory = nil
		MLX.Memory.clearCache()
	}

	/// Generates a reply for `system` + `user`. `onText` receives the text
	/// produced so far (for live display). Stops early on cancellation, on
	/// `stopSequences` or after `maxTokens`.
	public func generate(
		system: String,
		user: String,
		maxTokens: Int,
		stopSequences: [String] = [],
		onText: (@Sendable (String) -> Void)? = nil
	) async throws -> String {
		guard let container else { throw LocalLLMError.notLoaded }
		let output = try await container.perform { context in
			let ids = try Self.promptTokens(system: system, user: user, tokenizer: context.tokenizer)
			let input = LMInput(tokens: MLXArray(ids))
			let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
			var result = ""
			let stream = try MLXLMCommon.generate(input: input, cache: nil, parameters: parameters, context: context)
			for await item in stream {
				if Task.isCancelled { break }
				guard case let .chunk(chunk) = item else { continue }
				result += chunk
				if let stop = stopSequences.first(where: { result.contains($0) }), let range = result.range(of: stop) {
					result = String(result[..<range.lowerBound])
					break
				}
				onText?(result)
			}
			return result
		}
		// Do not keep the generation buffers around between tasks.
		MLX.Memory.clearCache()
		return output
	}

	/// Chat template with reasoning ("thinking") disabled; models whose
	/// template rejects a system turn get the instructions inside the user turn.
	static func promptTokens(system: String, user: String, tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
		let context: [String: any Sendable] = ["enable_thinking": false]
		do {
			return try tokenizer.applyChatTemplate(
				messages: [["role": "system", "content": system], ["role": "user", "content": user]],
				tools: nil,
				additionalContext: context
			)
		} catch MLXLMCommon.TokenizerError.missingChatTemplate {
			return tokenizer.encode(text: "\(system)\n\n\(user)\n\n")
		} catch {
			return try tokenizer.applyChatTemplate(
				messages: [["role": "user", "content": "\(system)\n\n\(user)"]],
				tools: nil,
				additionalContext: context
			)
		}
	}
}
