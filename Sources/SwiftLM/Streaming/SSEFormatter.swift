// SSEFormatter.swift — Type-safe SSE chunk builders for OpenAI-compatible streaming
//
// Replaces hand-built [String: Any] dictionaries + try! with Codable structs
// and safe JSONEncoder usage. Each function produces an SSE "data:" line.

import Foundation
import HTTPTypes
import Hummingbird

// MARK: - HTTP Helpers

func jsonHeaders() -> HTTPFields {
    HTTPFields([HTTPField(name: .contentType, value: "application/json")])
}

func sseHeaders() -> HTTPFields {
    HTTPFields([
        HTTPField(name: .contentType, value: "text/event-stream"),
        HTTPField(name: .cacheControl, value: "no-cache"),
        HTTPField(name: HTTPField.Name("X-Accel-Buffering")!, value: "no"),
    ])
}

// MARK: - Request Body Collection

func collectBody(_ request: Request) async throws -> Data {
    var bodyBuffer = try await request.body.collect(upTo: 10 * 1024 * 1024)
    let bodyBytes = bodyBuffer.readBytes(length: bodyBuffer.readableBytes) ?? []
    return Data(bodyBytes)
}

// MARK: - Stop Sequence Detection

func checkStopSequences(_ text: String, stopSequences: [String]) -> (String, String)? {
    for stop in stopSequences {
        if let range = text.range(of: stop) {
            let trimmed = String(text[text.startIndex..<range.lowerBound])
            return (trimmed, stop)
        }
    }
    return nil
}

// MARK: - SSE Encoding

private let sseEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [] // compact JSON
    return encoder
}()

private func sseEvent(_ data: Data) -> String {
    guard let json = String(data: data, encoding: .utf8) else {
        return "data: {\"error\":\"encoding_failed\"}\r\n\r\n"
    }
    return "data: \(json)\r\n\r\n"
}

// MARK: - Chat Completion Chunk

private struct SSEChatChunk: Encodable {
    let id: String
    let object: String = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [SSEChatChoice]
}

private struct SSEChatChoice: Encodable {
    let index: Int
    let delta: SSEDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }
}

private struct SSEDelta: Encodable {
    let role: String?
    let content: String?
    let reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case reasoningContent = "reasoning_content"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let role { try container.encode(role, forKey: .role) }
        if let content { try container.encode(content, forKey: .content) }
        if let reasoningContent { try container.encode(reasoningContent, forKey: .reasoningContent) }
    }
}

func sseChunk(modelId: String, reasoningContent: String?, content: String?, finishReason: String?) -> String {
    let hasContent = reasoningContent != nil || content != nil
    let delta = SSEDelta(
        role: hasContent ? "assistant" : nil,
        content: content,
        reasoningContent: reasoningContent
    )
    let chunk = SSEChatChunk(
        id: "chatcmpl-\(UUID().uuidString)",
        created: Int(Date().timeIntervalSince1970),
        model: modelId,
        choices: [SSEChatChoice(index: 0, delta: delta, finishReason: finishReason)]
    )
    do {
        let data = try sseEncoder.encode(chunk)
        return sseEvent(data)
    } catch {
        return "data: {\"error\":\"encoding_failed\"}\r\n\r\n"
    }
}

// MARK: - Prefill Progress Chunk

private struct SSEPrefillChunk: Encodable {
    let id: String
    let object: String = "prefill_progress"
    let created: Int
    let model: String
    let prefill: PrefillInfo
}

private struct PrefillInfo: Encodable {
    let status: String = "processing"
    let nPast: Int
    let nPromptTokens: Int
    let fraction: Double
    let elapsedSeconds: Int

    enum CodingKeys: String, CodingKey {
        case status
        case nPast = "n_past"
        case nPromptTokens = "n_prompt_tokens"
        case fraction
        case elapsedSeconds = "elapsed_seconds"
    }
}

func ssePrefillChunk(modelId: String, nPast: Int = 0, promptTokens: Int, elapsedSeconds: Int) -> String {
    let fraction = promptTokens > 0 ? Double(nPast) / Double(promptTokens) : 0.0
    let chunk = SSEPrefillChunk(
        id: "prefill-\(UUID().uuidString)",
        created: Int(Date().timeIntervalSince1970),
        model: modelId,
        prefill: PrefillInfo(
            nPast: nPast,
            nPromptTokens: promptTokens,
            fraction: fraction,
            elapsedSeconds: elapsedSeconds
        )
    )
    do {
        let data = try sseEncoder.encode(chunk)
        return sseEvent(data)
    } catch {
        return "data: {\"error\":\"encoding_failed\"}\r\n\r\n"
    }
}

// MARK: - Usage Chunk

private struct SSEUsageChunk: Encodable {
    let id: String
    let object: String = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [SSEEmptyChoice]
    let usage: TokenUsage
}

private struct SSEEmptyChoice: Encodable {}

func sseUsageChunk(modelId: String, promptTokens: Int, completionTokens: Int) -> String {
    let chunk = SSEUsageChunk(
        id: "chatcmpl-\(UUID().uuidString)",
        created: Int(Date().timeIntervalSince1970),
        model: modelId,
        choices: [],
        usage: TokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens
        )
    )
    do {
        let data = try sseEncoder.encode(chunk)
        return sseEvent(data)
    } catch {
        return "data: {\"error\":\"encoding_failed\"}\r\n\r\n"
    }
}

// MARK: - Tool Call Chunk

private struct SSEToolCallChunk: Encodable {
    let id: String
    let object: String = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [SSEToolCallChoice]
}

private struct SSEToolCallChoice: Encodable {
    let index: Int
    let delta: SSEToolCallDelta
}

private struct SSEToolCallDelta: Encodable {
    let role: String = "assistant"
    let toolCalls: [SSEToolCall]

    enum CodingKeys: String, CodingKey {
        case role
        case toolCalls = "tool_calls"
    }
}

private struct SSEToolCall: Encodable {
    let index: Int
    let id: String
    let type: String = "function"
    let function: SSEToolCallFunc
}

private struct SSEToolCallFunc: Encodable {
    let name: String
    let arguments: String
}

func sseToolCallChunk(modelId: String, index: Int, name: String, arguments: String) -> String {
    let toolCall = SSEToolCall(
        index: index,
        id: "call_\(UUID().uuidString.prefix(8))",
        function: SSEToolCallFunc(name: name, arguments: arguments)
    )
    let chunk = SSEToolCallChunk(
        id: "chatcmpl-\(UUID().uuidString)",
        created: Int(Date().timeIntervalSince1970),
        model: modelId,
        choices: [SSEToolCallChoice(index: 0, delta: SSEToolCallDelta(toolCalls: [toolCall]))]
    )
    do {
        let data = try sseEncoder.encode(chunk)
        return sseEvent(data)
    } catch {
        return "data: {\"error\":\"encoding_failed\"}\r\n\r\n"
    }
}

// MARK: - Text Completion Chunk

private struct SSETextChunk: Encodable {
    let id: String
    let object: String = "text_completion"
    let created: Int
    let model: String
    let choices: [SSETextChoice]
}

private struct SSETextChoice: Encodable {
    let index: Int
    let text: String
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, text
        case finishReason = "finish_reason"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(text, forKey: .text)
        if let finishReason {
            try container.encode(finishReason, forKey: .finishReason)
        }
    }
}

func sseTextChunk(modelId: String, text: String, finishReason: String?) -> String {
    let chunk = SSETextChunk(
        id: "cmpl-\(UUID().uuidString)",
        created: Int(Date().timeIntervalSince1970),
        model: modelId,
        choices: [SSETextChoice(index: 0, text: text, finishReason: finishReason)]
    )
    do {
        let data = try sseEncoder.encode(chunk)
        return sseEvent(data)
    } catch {
        return "data: {\"error\":\"encoding_failed\"}\r\n\r\n"
    }
}
