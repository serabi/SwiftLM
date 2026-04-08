// ChatHandler.swift — OpenAI-compatible chat completion endpoint handlers
//
// Handles: /v1/chat/completions (streaming + non-streaming)
// Includes: request parsing, message conversion, cache-aware generation,
// thinking state tracking, tool call support, prefill heartbeat.

import Foundation
import HTTPTypes
import Hummingbird
import Hub
import Logging
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

// MARK: - Prefill State

/// Tracks prefill progress: whether it is done, and how many tokens have been processed.
/// n_past is updated by activePrefillProgressHook (called from LLMModel.prepare after each chunk)
/// and read by the SSE heartbeat task every 2 s.
private actor PrefillState {
    private(set) var done: Bool = false
    private(set) var nPast: Int = 0
    func finish() { done = true }
    func update(nPast: Int) { self.nPast = nPast }
}

// MARK: - Chat Completions Handler

func handleChatCompletion(
    bodyData: Data,
    config: ServerConfig,
    container: ModelContainer,
    semaphore: AsyncSemaphore,
    stats: ServerStats,
    promptCache: PromptCache
) async throws -> Response {
    let chatReq = try JSONDecoder().decode(ChatCompletionRequest.self, from: bodyData)
    let isStream = chatReq.stream ?? false
    let jsonMode = chatReq.responseFormat?.type == "json_object"

    // Merge per-request overrides with CLI defaults
    let tokenLimit = chatReq.maxTokens ?? config.maxTokens
    let temperature = chatReq.temperature.map(Float.init) ?? config.temp
    let topP = chatReq.topP.map(Float.init) ?? config.topP
    let repeatPenalty = chatReq.repetitionPenalty.map(Float.init) ?? config.repeatPenalty
    let stopSequences = chatReq.stop ?? []
    let includeUsage = chatReq.streamOptions?.includeUsage ?? false

    // Log extra sampling params if provided (accepted for API compat, not all are used)
    if chatReq.topK != nil || chatReq.frequencyPenalty != nil || chatReq.presencePenalty != nil {
        // These are accepted but may not affect generation if MLX doesn't support them
    }

    let params = GenerateParameters(
        maxTokens: tokenLimit,
        maxKVSize: config.ctxSize,
        temperature: temperature,
        topP: topP,
        repetitionPenalty: repeatPenalty,
        prefillStepSize: config.prefillSize
    )

    // Seed for deterministic generation
    if let seed = chatReq.seed {
        MLXRandom.seed(UInt64(seed))
    }

    // Parse messages with multipart content support (for VLM images)
    var chatMessages: [Chat.Message] = []
    var systemPromptText = ""
    for msg in chatReq.messages {
        let textContent = msg.textContent
        let images = msg.extractImages()
        switch msg.role {
        case "system", "developer":
            chatMessages.append(.system(textContent, images: images))
            systemPromptText += textContent
        case "assistant":
            var formattedToolCalls: [[String: any Sendable]]? = nil
            if let tc = msg.tool_calls, !tc.isEmpty {
                formattedToolCalls = tc.map { call in
                    [
                        "id": call.id,
                        "type": call.type,
                        "function": [
                            "name": call.function.name,
                            "arguments": call.function.arguments
                        ] as [String: any Sendable]
                    ] as [String: any Sendable]
                }
            }
            chatMessages.append(.assistant(textContent, images: images, toolCalls: formattedToolCalls))
        case "tool":
            chatMessages.append(.tool(textContent, toolCallId: msg.tool_call_id))
        default:
            chatMessages.append(.user(textContent, images: images))
        }
    }

    // JSON mode: inject system prompt for JSON output
    if jsonMode {
        let jsonStr = "You must respond with valid JSON only. No markdown code fences, no explanation text, no preamble. Output raw JSON."
        if !chatMessages.isEmpty && chatMessages[0].role == .system {
            chatMessages[0].content += "\n\n" + jsonStr
        } else {
            chatMessages.insert(.system(jsonStr), at: 0)
        }
        systemPromptText = "JSON_MODE:" + systemPromptText
    }

    // Convert OpenAI tools format -> [String: any Sendable] for UserInput
    let toolSpecs: [[String: any Sendable]]? = chatReq.tools?.map { tool in
        var spec: [String: any Sendable] = ["type": tool.type]
        var fn: [String: any Sendable] = ["name": tool.function.name]
        if let desc = tool.function.description { fn["description"] = desc }
        if let params = tool.function.parameters {
            fn["parameters"] = params.mapValues { $0.value }
        }
        spec["function"] = fn
        return spec
    }

    // Acquire slot (concurrency limiter)
    await semaphore.wait()
    await stats.requestStarted()
    let genStart = Date()

    // Pass enable_thinking to the Jinja chat template via additionalContext.
    // Precedence: top-level request > per-request chat_template_kwargs > server --thinking flag
    let enableThinking: Bool
    if let explicitTopLevel = chatReq.enableThinking {
        enableThinking = explicitTopLevel
    } else if let kwargs = chatReq.chatTemplateKwargs, let perRequest = kwargs["enable_thinking"] {
        enableThinking = perRequest
    } else {
        enableThinking = config.thinking
    }
    let templateContext: [String: any Sendable]? = enableThinking ? nil : ["enable_thinking": false]
    let userInput = UserInput(chat: chatMessages, tools: toolSpecs, additionalContext: templateContext)
    let lmInput = try await container.prepare(input: userInput)

    // Prompt caching: full token sequence for prefix matching
    let promptTokenCount = lmInput.text.tokens.size
    let promptTokens = lmInput.text.tokens.asArray(Int.self)

    // llama-server style: announce prefill start
    Log.debug("srv  slot_launch: id 0 | prompt=\(promptTokenCount)t | thinking=\(enableThinking) | prefilling...")
    fflush(stdout)
    let prefillStart = Date()

    // Cache-aware generation
    let (stream, onPrefillDone) = try await container.perform { context -> (AsyncStream<Generation>, (() async -> Void)?) in
        let cache = context.model.newCache(parameters: params)

        // TurboQuant: enable 3-bit KV compression on every KVCacheSimple layer
        if config.turboKV {
            for layer in cache {
                if let simple = layer as? KVCacheSimple {
                    simple.turboQuantEnabled = true
                }
            }
        }

        // Try to restore via token-by-token prefix match (llama-server style)
        var stream: AsyncStream<Generation>
        if let cachedCount = await promptCache.restore(newTokens: promptTokens, into: cache) {
            var startIndex = cachedCount
            if startIndex >= lmInput.text.tokens.count {
                startIndex = lmInput.text.tokens.count - 1
                for layer in cache { layer.trim(1) }
            }
            let remainingTokens = lmInput.text.tokens[startIndex...]
            let trimmedInput = LMInput(tokens: remainingTokens)
            stream = try MLXLMCommon.generate(
                input: trimmedInput, cache: cache, parameters: params, context: context
            )
        } else {
            stream = try MLXLMCommon.generate(
                input: lmInput, cache: cache, parameters: params, context: context
            )
        }

        // TurboQuant guard: skip prompt cache save when compression is active
        let turboHasCompressed = cache.contains { layer in
            if let simple = layer as? KVCacheSimple {
                return simple.turboQuantEnabled && simple.compressedOffset > 0
            }
            return false
        }
        let onPrefillDone: (() async -> Void)? = {
            if turboHasCompressed {
                Log.info("Skipping prompt cache save -- TurboQuant has compressed \(cache.compactMap { ($0 as? KVCacheSimple)?.compressedOffset }.max() ?? 0) tokens. Saving would decode ~37 GB back to fp16.")
            } else {
                await promptCache.save(tokens: promptTokens, cache: cache)
            }
        }
        return (stream, onPrefillDone)
    }

    let modelId = config.modelId

    if isStream {
        return handleChatStreaming(
            stream: stream, modelId: modelId, stopSequences: stopSequences,
            includeUsage: includeUsage, promptTokenCount: promptTokenCount,
            enableThinking: enableThinking, jsonMode: jsonMode, semaphore: semaphore,
            stats: stats, genStart: genStart, prefillStart: prefillStart, onPrefillDone: onPrefillDone
        )
    } else {
        return try await handleChatNonStreaming(
            stream: stream, modelId: modelId, stopSequences: stopSequences,
            promptTokenCount: promptTokenCount, enableThinking: enableThinking,
            jsonMode: jsonMode, semaphore: semaphore,
            stats: stats, genStart: genStart, prefillStart: prefillStart, onPrefillDone: onPrefillDone
        )
    }
}

// MARK: - Chat Streaming

func handleChatStreaming(
    stream: AsyncStream<Generation>,
    modelId: String,
    stopSequences: [String],
    includeUsage: Bool,
    promptTokenCount: Int,
    enableThinking: Bool = false,
    jsonMode: Bool = false,
    semaphore: AsyncSemaphore,
    stats: ServerStats,
    genStart: Date,
    prefillStart: Date,
    onPrefillDone: (() async -> Void)? = nil
) -> Response {
    let (sseStream, cont) = AsyncStream<String>.makeStream()

    // Prefill heartbeat: emit llama-server-style slot_update progress every 2 s
    let prefillState = PrefillState()
    activePrefillProgressHook = { nPast, _ in
        Task { await prefillState.update(nPast: nPast) }
    }
    Task {
        var elapsed = 0
        while await !prefillState.done {
            try? await Task.sleep(for: .seconds(2))
            if await !prefillState.done {
                elapsed += 2
                let nPast = await prefillState.nPast
                _ = cont.yield(ssePrefillChunk(
                    modelId: modelId,
                    nPast: nPast,
                    promptTokens: promptTokenCount,
                    elapsedSeconds: elapsed))
            }
        }
    }

    Task {
        var hasToolCalls = false
        var toolCallIndex = 0
        var completionTokenCount = 0
        var fullText = ""
        var stopped = false
        var firstToken = true
        var tracker = ThinkingStateTracker()

        // JSON mode streaming: buffer early tokens to strip hallucinated prefixes
        var jsonBuffering = jsonMode
        var jsonBuffer = ""

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
                // Signal first token -- stops the prefill heartbeat task
                if firstToken {
                    activePrefillProgressHook = nil
                    await prefillState.finish()
                    let prefillDur = Date().timeIntervalSince(prefillStart)
                    let prefillTokPerSec = prefillDur > 0 ? Double(promptTokenCount) / prefillDur : 0
                    let memSnap = MemoryUtils.snapshot()
                    Log.debug("srv  slot update: id 0 | prefill done | n_tokens=\(promptTokenCount), t=\(String(format: "%.2f", prefillDur))s, \(String(format: "%.1f", prefillTokPerSec))t/s | OS_RAM=\(String(format: "%.1f", memSnap.os))GB | MEM_DEMAND=\(String(format: "%.1f", memSnap.demand))GB | GPU_MEM=\(String(format: "%.1f", memSnap.gpu))GB")
                    Log.debug("srv  generate: id 0")
                    if let onPrefillDone { await onPrefillDone() }
                    firstToken = false
                }
                print(text, terminator: "")
                fflush(stdout)

                // JSON mode buffering: accumulate early tokens, strip prefix, then flush
                if jsonBuffering {
                    jsonBuffer += text
                    let trimmed = jsonBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    let enoughTokens = completionTokenCount >= 3
                    let hitMax = completionTokenCount >= 32
                    let hasDoubleBrace = enoughTokens && trimmed.hasPrefix("{") && trimmed.dropFirst().contains("{")

                    if hitMax || hasDoubleBrace {
                        var cleaned = trimmed
                        if hasDoubleBrace {
                            if let firstBrace = cleaned.firstIndex(of: "{") {
                                let afterFirst = cleaned.index(after: firstBrace)
                                if let secondBrace = cleaned[afterFirst...].firstIndex(of: "{") {
                                    cleaned = String(cleaned[secondBrace...])
                                }
                            }
                        }
                        let (rText, cText) = enableThinking ? tracker.process(cleaned) : ("", cleaned)
                        if !rText.isEmpty || !cText.isEmpty {
                            cont.yield(sseChunk(
                                modelId: modelId,
                                reasoningContent: rText.isEmpty ? nil : rText,
                                content: cText.isEmpty ? nil : cText,
                                finishReason: nil
                            ))
                        }
                        jsonBuffering = false
                    }
                    continue
                }

                // Route text through thinking state machine
                let (reasoningText, contentText) = enableThinking
                    ? tracker.process(text)
                    : ("", text)

                // Stop sequence check (operate on full accumulated text)
                if let (trimmedFull, _) = checkStopSequences(fullText, stopSequences: stopSequences) {
                    let emittedSoFar = fullText.count - text.count
                    if trimmedFull.count > emittedSoFar {
                        let partialText = String(trimmedFull.suffix(trimmedFull.count - emittedSoFar))
                        let (r, c) = enableThinking ? tracker.process(partialText) : ("", partialText)
                        cont.yield(sseChunk(modelId: modelId, reasoningContent: r.isEmpty ? nil : r,
                                            content: c.isEmpty ? nil : c, finishReason: nil))
                    }
                    cont.yield(sseChunk(modelId: modelId, reasoningContent: nil, content: nil, finishReason: "stop"))
                    if includeUsage {
                        cont.yield(sseUsageChunk(modelId: modelId, promptTokens: promptTokenCount, completionTokens: completionTokenCount))
                    }
                    cont.yield("data: [DONE]\r\n\r\n")
                    cont.finish()
                    stopped = true
                } else {
                    let hasReasoning = !reasoningText.isEmpty
                    let hasContent = !contentText.isEmpty
                    if hasReasoning || hasContent {
                        cont.yield(sseChunk(
                            modelId: modelId,
                            reasoningContent: hasReasoning ? reasoningText : nil,
                            content: hasContent ? contentText : nil,
                            finishReason: nil
                        ))
                    }
                }

            case .toolCall(let tc):
                hasToolCalls = true
                let argsJson = serializeToolCallArgs(tc.function.arguments)
                cont.yield(sseToolCallChunk(modelId: modelId, index: toolCallIndex, name: tc.function.name, arguments: argsJson))
                toolCallIndex += 1

            case .info(let info):
                activePrefillProgressHook = nil
                await prefillState.finish()
                if !stopped {
                    var reason: String
                    switch info.stopReason {
                    case .length:
                        reason = "length"
                    case .cancelled, .stop:
                        reason = hasToolCalls ? "tool_calls" : "stop"
                    }
                    cont.yield(sseChunk(modelId: modelId, reasoningContent: nil, content: nil, finishReason: reason))
                    if includeUsage {
                        cont.yield(sseUsageChunk(modelId: modelId, promptTokens: promptTokenCount, completionTokens: completionTokenCount))
                    }
                    cont.yield("data: [DONE]\r\n\r\n")
                    cont.finish()
                    print("")
                    let postMemSnap = MemoryUtils.snapshot()
                    Log.debug("srv  slot done: id 0 | gen_tokens=\(completionTokenCount) | OS_RAM=\(String(format: "%.1f", postMemSnap.os))GB | MEM_DEMAND=\(String(format: "%.1f", postMemSnap.demand))GB | GPU_MEM=\(String(format: "%.1f", postMemSnap.gpu))GB")
                    let dur = Date().timeIntervalSince(genStart)
                    let tokPerSec = dur > 0 ? Double(completionTokenCount) / dur : 0
                    let logContent: Any = hasToolCalls ? NSNull() : fullText
                    let logResp: [String: Any] = [
                        "choices": [[
                            "index": 0,
                            "message": ["role": "assistant", "content": logContent],
                            "finish_reason": reason
                        ]],
                        "usage": [
                            "prompt_tokens": promptTokenCount,
                            "completion_tokens": completionTokenCount,
                            "total_tokens": promptTokenCount + completionTokenCount
                        ],
                        "timings": ["predicted_per_second": tokPerSec]
                    ]
                    if let logData = try? JSONSerialization.data(withJSONObject: logResp),
                       let logStr = String(data: logData, encoding: .utf8) {
                        Log.debug("srv  log_server_r: response: \(logStr)")
                    }
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

// MARK: - Chat Non-Streaming

func handleChatNonStreaming(
    stream: AsyncStream<Generation>,
    modelId: String,
    stopSequences: [String],
    promptTokenCount: Int,
    enableThinking: Bool = false,
    jsonMode: Bool = false,
    semaphore: AsyncSemaphore,
    stats: ServerStats,
    genStart: Date,
    prefillStart: Date,
    onPrefillDone: (() async -> Void)? = nil
) async throws -> Response {
    var fullText = ""
    var completionTokenCount = 0
    var collectedToolCalls: [ToolCallResponse] = []
    var tcIndex = 0
    var generationStopReason: GenerateStopReason = .stop
    var firstToken = true
    for await generation in stream {
        switch generation {
        case .chunk(let text, _):
            fullText += text
            completionTokenCount += 1
            // GPU yield: prevent Metal from starving macOS WindowServer
            if completionTokenCount % 8 == 0 {
                try? await Task.sleep(for: .microseconds(50))
            }
            if firstToken {
                let prefillDur = Date().timeIntervalSince(prefillStart)
                let prefillTokPerSec = prefillDur > 0 ? Double(promptTokenCount) / prefillDur : 0
                let memSnap = MemoryUtils.snapshot()
                Log.debug("srv  slot update: id 0 | prefill done | n_tokens=\(promptTokenCount), t=\(String(format: "%.2f", prefillDur))s, \(String(format: "%.1f", prefillTokPerSec))t/s | OS_RAM=\(String(format: "%.1f", memSnap.os))GB | MEM_DEMAND=\(String(format: "%.1f", memSnap.demand))GB | GPU_MEM=\(String(format: "%.1f", memSnap.gpu))GB")
                Log.debug("srv  generate: id 0")
                if let onPrefillDone { await onPrefillDone() }
                firstToken = false
            }
            print(text, terminator: "")
            fflush(stdout)
        case .toolCall(let tc):
            let argsJson = serializeToolCallArgs(tc.function.arguments)
            collectedToolCalls.append(ToolCallResponse(
                id: "call_\(UUID().uuidString.prefix(8))",
                type: "function",
                function: ToolCallFunction(name: tc.function.name, arguments: argsJson)
            ))
            tcIndex += 1
        case .info(let info):
            generationStopReason = info.stopReason
        }
    }
    print("")
    let postMemSnap = MemoryUtils.snapshot()
    Log.debug("srv  slot done: id 0 | gen_tokens=\(completionTokenCount) | OS_RAM=\(String(format: "%.1f", postMemSnap.os))GB | MEM_DEMAND=\(String(format: "%.1f", postMemSnap.demand))GB | GPU_MEM=\(String(format: "%.1f", postMemSnap.gpu))GB")
    let duration = Date().timeIntervalSince(genStart)
    await stats.requestFinished(tokens: completionTokenCount, duration: duration)
    await semaphore.signal()

    // Apply stop sequences to final text
    var finishReason: String
    switch generationStopReason {
    case .length:
        finishReason = "length"
    default:
        finishReason = "stop"
    }
    if let (trimmedText, _) = checkStopSequences(fullText, stopSequences: stopSequences) {
        fullText = trimmedText
        finishReason = "stop"
    }

    // Thinking: extract <think>...</think> into reasoning_content
    var reasoningContent: String? = nil
    var responseContent = fullText
    if enableThinking {
        let (extracted, remaining) = extractThinkingBlock(from: fullText)
        if let extracted {
            reasoningContent = extracted
            responseContent = remaining
        }
    }

    // JSON mode validation
    if jsonMode {
        let stripped = responseContent
            .replacingOccurrences(of: "```json\n", with: "")
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```\n", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        responseContent = stripped
    }

    let totalTokens = promptTokenCount + completionTokenCount
    let hasToolCalls = !collectedToolCalls.isEmpty

    let resp = ChatCompletionResponse(
        id: "chatcmpl-\(UUID().uuidString)",
        model: modelId,
        created: Int(Date().timeIntervalSince1970),
        choices: [
            Choice(
                index: 0,
                message: AssistantMessage(
                    role: "assistant",
                    content: responseContent.isEmpty && hasToolCalls ? nil : responseContent,
                    reasoningContent: reasoningContent,
                    toolCalls: hasToolCalls ? collectedToolCalls : nil
                ),
                finishReason: hasToolCalls ? "tool_calls" : finishReason
            )
        ],
        usage: TokenUsage(promptTokens: promptTokenCount, completionTokens: completionTokenCount, totalTokens: totalTokens)
    )
    let encoded = try JSONEncoder().encode(resp)
    if let responseStr = String(data: encoded, encoding: .utf8) {
        Log.debug("srv  log_server_r: response: \(responseStr)")
    }
    return Response(
        status: .ok,
        headers: jsonHeaders(),
        body: .init(byteBuffer: ByteBuffer(data: encoded))
    )
}
