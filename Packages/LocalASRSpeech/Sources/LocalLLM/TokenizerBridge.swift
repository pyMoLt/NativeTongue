import Foundation
import MLXLMCommon
import Tokenizers

/// Adapts swift-transformers 1.1.x tokenizers to mlx-swift-lm's `Tokenizer`.
///
/// mlx-swift-lm's own Hugging Face integration needs swift-transformers ≥ 1.3,
/// while WhisperKit 0.15 pins 1.1.x, so the app bridges the protocol itself.
struct TokenizerBridge: MLXLMCommon.Tokenizer {
	private let upstream: any Tokenizers.Tokenizer

	init(_ upstream: any Tokenizers.Tokenizer) {
		self.upstream = upstream
	}

	func encode(text: String, addSpecialTokens: Bool) -> [Int] {
		upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
	}

	func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
		upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
	}

	func convertTokenToId(_ token: String) -> Int? {
		upstream.convertTokenToId(token)
	}

	func convertIdToToken(_ id: Int) -> String? {
		upstream.convertIdToToken(id)
	}

	var bosToken: String? { upstream.bosToken }
	var eosToken: String? { upstream.eosToken }
	var unknownToken: String? { upstream.unknownToken }

	func applyChatTemplate(
		messages: [[String: any Sendable]],
		tools: [[String: any Sendable]]?,
		additionalContext: [String: any Sendable]?
	) throws -> [Int] {
		do {
			return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
		} catch Tokenizers.TokenizerError.missingChatTemplate {
			throw MLXLMCommon.TokenizerError.missingChatTemplate
		}
	}
}

/// Loads the tokenizer from the model folder only (no network).
struct LocalTokenizerLoader: TokenizerLoader {
	func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
		let upstream = try await AutoTokenizer.from(modelFolder: directory)
		return TokenizerBridge(upstream)
	}
}
