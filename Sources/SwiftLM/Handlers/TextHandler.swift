// TextHandler.swift — OpenAI-compatible text completion endpoint handlers
//
// Handles: /v1/completions (streaming + non-streaming)

import Foundation
import HTTPTypes
import Hummingbird
import MLX
import MLXLMCommon

// MARK: - Text Completions Handler

func handleTextCompletion(
    bodyData: Data,
    config: ServerConfig,
    container: ModelContainer,
    semaphore: AsyncSemaphore,
    stats: ServerStats
) async throws -> Response {
    let compReq = try JSONDecoder().decode(TextCompletionRequest.self, from: bodyData)
    let isStream = compReq.stream ?? false

    let tokenLimit = compReq.maxTokens ?? config.maxTokens
    let temperature = compReq.temperature.map(Float.init) ?? config.temp
    let topP = compReq.topP.map(Float.init) ?? config.topP
    let repeatPenalty = compReq.repetitionPenalty.map(Float.init) ?? config.repeatPenalty
    let stopSequences = compReq.stop ?? []

    let params = GenerateParameters(
        maxTokens: tokenLimit,
        maxKVSize: config.ctxSize,
        temperature: temperature,
        topP: topP,
        repetitionPenalty: repeatPenalty,
        prefillStepSize: config.prefillSize
    )

    if let seed = compReq.seed {
        MLXRandom.seed(UInt64(seed))
    }

    await semaphore.wait()
    await stats.requestStarted()
    let genStart = Date()

    let userInput = UserInput(prompt: compReq.prompt)
    let lmInput = try await container.prepare(input: userInput)

    // Get actual prompt token count before generate() to avoid data race
    let promptTokenCount = lmInput.text.tokens.size

    let stream = try await container.generate(input: lmInput, parameters: params)
    let modelId = config.modelId

    if isStream {
        return handleTextStreaming(
            stream: stream, modelId: modelId, stopSequences: stopSequences,
            semaphore: semaphore, stats: stats, genStart: genStart
        )
    } else {
        return try await handleTextNonStreaming(
            stream: stream, modelId: modelId, stopSequences: stopSequences,
            promptTokenCount: promptTokenCount, semaphore: semaphore, stats: stats, genStart: genStart
        )
    }
}

// MARK: - Text Streaming

func handleTextStreaming(
    stream: AsyncStream<Generation>,
    modelId: String,
    stopSequences: [String],
    semaphore: AsyncSemaphore,
    stats: ServerStats,
    genStart: Date
) -> Response {
    let (sseStream, cont) = AsyncStream<String>.makeStream()
    Task {
        var completionTokenCount = 0
        var fullText = ""
        var stopped = false
        for await generation in stream {
            if stopped { break }
            switch generation {
            case .chunk(let text, _):
                completionTokenCount += 1
                fullText += text
                // GPU yield: prevent Metal from starving macOS WindowServer
                if completionTokenCount % 8 == 0 {
                    try? await Task.sleep(for: .microseconds(50))
                }
                if let (trimmedText, _) = checkStopSequences(fullText, stopSequences: stopSequences) {
                    let emittedSoFar = fullText.count - text.count
                    if trimmedText.count > emittedSoFar {
                        let partialText = String(trimmedText.suffix(trimmedText.count - emittedSoFar))
                        cont.yield(sseTextChunk(modelId: modelId, text: partialText, finishReason: nil))
                    }
                    cont.yield(sseTextChunk(modelId: modelId, text: "", finishReason: "stop"))
                    cont.yield("data: [DONE]\n\n")
                    cont.finish()
                    stopped = true
                } else {
                    cont.yield(sseTextChunk(modelId: modelId, text: text, finishReason: nil))
                }
            case .toolCall:
                break
            case .info(let info):
                if !stopped {
                    var reason: String
                    switch info.stopReason {
                    case .length:
                        reason = "length"
                    case .cancelled, .stop:
                        reason = "stop"
                    }
                    cont.yield(sseTextChunk(modelId: modelId, text: "", finishReason: reason))
                    cont.yield("data: [DONE]\n\n")
                    cont.finish()
                }
            }
        }
        cont.finish()
        let duration = Date().timeIntervalSince(genStart)
        await stats.requestFinished(tokens: completionTokenCount, duration: duration)
        await semaphore.signal()
    }
    return Response(
        status: .ok,
        headers: sseHeaders(),
        body: .init(asyncSequence: sseStream.map { ByteBuffer(string: $0) })
    )
}

// MARK: - Text Non-Streaming

func handleTextNonStreaming(
    stream: AsyncStream<Generation>,
    modelId: String,
    stopSequences: [String],
    promptTokenCount: Int,
    semaphore: AsyncSemaphore,
    stats: ServerStats,
    genStart: Date
) async throws -> Response {
    var fullText = ""
    var completionTokenCount = 0
    for await generation in stream {
        switch generation {
        case .chunk(let text, _):
            fullText += text
            completionTokenCount += 1
            // GPU yield: prevent Metal from starving macOS WindowServer
            if completionTokenCount % 8 == 0 {
                try? await Task.sleep(for: .microseconds(50))
            }
        case .toolCall, .info:
            break
        }
    }
    let duration = Date().timeIntervalSince(genStart)
    await stats.requestFinished(tokens: completionTokenCount, duration: duration)
    await semaphore.signal()

    var finishReason = "stop"
    if let (trimmedText, _) = checkStopSequences(fullText, stopSequences: stopSequences) {
        fullText = trimmedText
        finishReason = "stop"
    }

    let totalTokens = promptTokenCount + completionTokenCount

    let resp = TextCompletionResponse(
        id: "cmpl-\(UUID().uuidString)",
        model: modelId,
        created: Int(Date().timeIntervalSince1970),
        choices: [
            TextChoice(index: 0, text: fullText, finishReason: finishReason)
        ],
        usage: TokenUsage(promptTokens: promptTokenCount, completionTokens: completionTokenCount, totalTokens: totalTokens)
    )
    let encoded = try JSONEncoder().encode(resp)
    return Response(
        status: .ok,
        headers: jsonHeaders(),
        body: .init(byteBuffer: ByteBuffer(data: encoded))
    )
}
