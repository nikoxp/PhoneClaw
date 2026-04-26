import Foundation
import MLXLMCommon
import Tokenizers

/// Bridges `swift-tokenizers` to `MLXLMCommon.Tokenizer`.
struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        // iOS target depends on swift-transformers (huggingface) which uses
        // `decode(tokens:)` — CLI target uses swift-tokenizers (DePasqualeOrg)
        // which uses `decode(tokenIds:)`. PhoneClawCLI/.../MLXTokenizersLoader.swift
        // 是 CLI 自己那一份, 跟这个文件是两份独立 copy.
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
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch let error as Tokenizers.TokenizerError {
            if case .missingChatTemplate = error {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            throw error
        }
    }
}

struct MLXTokenizersLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        // iOS Xcode 用 swift-transformers (huggingface) 1.1.9, API 是
        // from(modelFolder:); CLI 那份 (PhoneClawCLI/.../MLXTokenizersLoader.swift)
        // 用 swift-tokenizers (DePasqualeOrg) 0.2.x, API 是 from(directory:).
        // 两份文件独立, 不要试图共用.
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return MLXTokenizerBridge(upstream)
    }
}
