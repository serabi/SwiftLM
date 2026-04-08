import Foundation
import Hub
import MLXLMCommon
import Tokenizers

// ── Hub/Tokenizer bridges (Downloader + TokenizerLoader conformances) ─────────

struct HubDownloader: Downloader, Sendable {
    let hub: HubApi
    func download(
        id: String, revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hub.snapshot(from: id, matching: patterns, progressHandler: progressHandler)
    }
}

struct TransformersTokenizerLoader: TokenizerLoader, Sendable {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let t = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(t)
    }
}

struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer, Sendable {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
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
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
