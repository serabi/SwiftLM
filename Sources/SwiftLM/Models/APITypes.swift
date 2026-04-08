// SwiftLM — OpenAI-compatible API request/response types

import CoreImage
import Foundation
import MLXLMCommon

func serializeToolCallArgs(_ args: [String: JSONValue]) -> String {
    let anyDict = args.mapValues { $0.anyValue }
    guard let data = try? JSONSerialization.data(withJSONObject: anyDict) else {
        return "{}"
    }
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - OpenAI-compatible types

struct StreamOptions: Decodable {
    let includeUsage: Bool?
    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

struct ResponseFormat: Decodable {
    let type: String
}

struct ChatCompletionRequest: Decodable {
    /// Message content can be a plain string or an array of content parts (text + image_url)
    struct Message: Decodable {
        let role: String
        let content: MessageContent?
        let tool_calls: [ToolCallResponse]?
        let tool_call_id: String?

        /// Extract plain text from content (handles both string and multipart)
        var textContent: String {
            guard let content = content else { return "" }
            switch content {
            case .string(let s): return s
            case .parts(let parts):
                return parts.compactMap { part in
                    if part.type == "text" { return part.text }
                    return nil
                }.joined(separator: "\n")
            }
        }

        /// Extract images from multipart content (base64 data URIs and HTTP URLs)
        func extractImages() -> [UserInput.Image] {
            guard let content = content, case .parts(let parts) = content else { return [] }
            return parts.compactMap { part -> UserInput.Image? in
                guard part.type == "image_url", let imageUrl = part.imageUrl else { return nil }
                let urlStr = imageUrl.url
                // Handle base64 data URIs: data:image/png;base64,...
                if urlStr.hasPrefix("data:") {
                    guard let commaIdx = urlStr.firstIndex(of: ",") else { return nil }
                    let base64Str = String(urlStr[urlStr.index(after: commaIdx)...])
                    guard let data = Data(base64Encoded: base64Str),
                          let ciImage = CIImage(data: data) else { return nil }
                    return .ciImage(ciImage)
                }
                // Handle HTTP/HTTPS URLs
                if let url = URL(string: urlStr),
                   (url.scheme == "http" || url.scheme == "https") {
                    return .url(url)
                }
                // Handle file URLs
                if let url = URL(string: urlStr) {
                    return .url(url)
                }
                return nil
            }
        }
    }

    /// Message content: either a plain string or structured multipart content
    enum MessageContent: Decodable {
        case string(String)
        case parts([ContentPart])

        init(from decoder: Swift.Decoder) throws {
            let svc = try decoder.singleValueContainer()
            if let str = try? svc.decode(String.self) {
                self = .string(str)
            } else if let parts = try? svc.decode([ContentPart].self) {
                self = .parts(parts)
            } else {
                self = .string("")
            }
        }
    }

    struct ContentPart: Decodable {
        let type: String
        let text: String?
        let imageUrl: ImageUrlContent?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageUrl = "image_url"
        }
    }

    struct ImageUrlContent: Decodable {
        let url: String
        let detail: String?
    }

    struct ToolDef: Decodable {
        let type: String
        let function: ToolFuncDef
    }
    struct ToolFuncDef: Decodable {
        let name: String
        let description: String?
        let parameters: [String: AnyCodable]?
    }
    let model: String?
    let messages: [Message]
    let stream: Bool?
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let topK: Int?
    let repetitionPenalty: Double?
    let frequencyPenalty: Double?
    let presencePenalty: Double?
    let tools: [ToolDef]?
    let stop: [String]?
    let seed: Int?
    let streamOptions: StreamOptions?
    let responseFormat: ResponseFormat?
    /// Per-request Jinja template kwargs (e.g. {"enable_thinking": false} for Qwen3/Qwen3.5)
    let chatTemplateKwargs: [String: Bool]?
    /// Top-level thinking override emitted by Aegis-AI gateway
    let enableThinking: Bool?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools, stop, seed
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case repetitionPenalty = "repetition_penalty"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case streamOptions = "stream_options"
        case responseFormat = "response_format"
        case chatTemplateKwargs = "chat_template_kwargs"
        case enableThinking = "enable_thinking"
    }
}

struct TextCompletionRequest: Decodable {
    let model: String?
    let prompt: String
    let stream: Bool?
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let repetitionPenalty: Double?
    let stop: [String]?
    let seed: Int?

    enum CodingKeys: String, CodingKey {
        case model, prompt, stream, temperature, stop, seed
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case repetitionPenalty = "repetition_penalty"
    }
}

struct ChatCompletionResponse: Encodable {
    let id: String
    let object: String = "chat.completion"
    let model: String
    let created: Int
    let choices: [Choice]
    let usage: TokenUsage
}

struct Choice: Encodable {
    let index: Int
    let message: AssistantMessage
    let finishReason: String

    enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
    }
}

struct AssistantMessage: Encodable {
    let role: String
    let content: String?
    /// Separated reasoning/thinking content (llama-server compatible).
    /// Only present when the model produced a <think>...</think> block.
    let reasoningContent: String?
    let toolCalls: [ToolCallResponse]?

    init(role: String, content: String?, reasoningContent: String? = nil, toolCalls: [ToolCallResponse]? = nil) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

struct ToolCallResponse: Codable {
    let id: String
    let type: String
    let function: ToolCallFunction
}

struct ToolCallFunction: Codable {
    let name: String
    let arguments: String
}

struct TextCompletionResponse: Encodable {
    let id: String
    let object: String = "text_completion"
    let model: String
    let created: Int
    let choices: [TextChoice]
    let usage: TokenUsage
}

struct TextChoice: Encodable {
    let index: Int
    let text: String
    let finishReason: String

    enum CodingKeys: String, CodingKey {
        case index, text
        case finishReason = "finish_reason"
    }
}

// AnyCodable: type-erased Decodable wrapper over JSON scalars/arrays/objects.
// `value` holds Sendable-safe Foundation types (Bool/Int/Double/String/NSNull + collections).
struct AnyCodable: @unchecked Sendable {
    let value: Any

    static func toSendable(_ dict: [String: AnyCodable]?) -> [String: any Sendable]? {
        guard let dict else { return nil }
        return dict.mapValues { $0.value as! any Sendable }
    }
}

extension AnyCodable: Decodable {
    init(from decoder: Swift.Decoder) throws {
        let c = try decoder.singleValueContainer()
        if (try? c.decodeNil()) == true { value = NSNull(); return }
        if let b = try? c.decode(Bool.self)   { value = b; return }
        if let i = try? c.decode(Int.self)    { value = i; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self) { value = s; return }
        if let a = try? c.decode([AnyCodable].self) { value = a.map { $0.value }; return }
        if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues { $0.value }; return }
        value = NSNull()
    }
}

struct TokenUsage: Encodable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}
