// Routes.swift — Hummingbird router setup and endpoint registration

import Foundation
import HTTPTypes
import Hummingbird
import MLXLMCommon

func buildRouter(
    config: ServerConfig,
    container: ModelContainer,
    semaphore: AsyncSemaphore,
    stats: ServerStats,
    promptCache: PromptCache,
    partitionPlan: PartitionPlan?,
    isSSDStream: Bool,
    corsOrigin: String?,
    apiKey: String?
) -> Router<BasicRequestContext> {
    let router = Router()

    // CORS middleware
    if let origin = corsOrigin {
        router.add(middleware: CORSMiddleware(allowedOrigin: origin))
    }

    // API key authentication middleware
    if let key = apiKey {
        router.add(middleware: ApiKeyMiddleware(apiKey: key))
    }

    let modelId = config.modelId
    let isVision = config.isVision

    // Health
    router.get("/health") { _, _ -> Response in
        await handleHealth(
            modelId: modelId,
            isVision: isVision,
            partitionPlan: partitionPlan,
            isSSDStream: isSSDStream,
            stats: stats
        )
    }

    // Models list
    router.get("/v1/models") { _, _ -> Response in
        handleModelList(modelId: modelId)
    }

    // Chat completions
    router.post("/v1/chat/completions") { request, _ -> Response in
        do {
            let bodyData = try await collectBody(request)
            return try await handleChatCompletion(
                bodyData: bodyData, config: config, container: container,
                semaphore: semaphore, stats: stats, promptCache: promptCache
            )
        } catch {
            let errMsg = String(describing: error).replacingOccurrences(of: "\"", with: "'")
            let payload = """
            {"error":{"message":"\(errMsg)","type":"server_error","code":"internal_error"}}
            """
            return Response(
                status: .internalServerError,
                headers: jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: payload))
            )
        }
    }

    // Text completions
    router.post("/v1/completions") { request, _ -> Response in
        do {
            let bodyData = try await collectBody(request)
            return try await handleTextCompletion(
                bodyData: bodyData, config: config, container: container,
                semaphore: semaphore, stats: stats
            )
        } catch {
            let errMsg = String(describing: error).replacingOccurrences(of: "\"", with: "'")
            let payload = """
            {"error":{"message":"\(errMsg)","type":"server_error","code":"internal_error"}}
            """
            return Response(
                status: .internalServerError,
                headers: jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: payload))
            )
        }
    }

    // Prometheus-compatible metrics
    router.get("/metrics") { _, _ -> Response in
        await handleMetrics(isSSDStream: isSSDStream, stats: stats)
    }

    // Human-friendly stats
    router.get("/stats") { _, _ -> Response in
        await handleStats(modelId: modelId, stats: stats)
    }

    return router
}
