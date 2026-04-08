import Foundation
import HTTPTypes
import Hummingbird

// ── API Key Authentication Middleware ────────────────────────────────────────

struct ApiKeyMiddleware<Context: RequestContext>: RouterMiddleware {
    let apiKey: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        // Exempt health and metrics endpoints from auth
        let path = request.uri.path
        if path == "/health" || path == "/metrics" {
            return try await next(request, context)
        }

        // Check Authorization header: "Bearer <key>"
        let authHeader = request.headers[values: .authorization].first ?? ""
        let expectedHeader = "Bearer \(apiKey)"

        if authHeader == expectedHeader || authHeader == apiKey {
            return try await next(request, context)
        }

        // Unauthorized
        let errorPayload = "{\"error\":{\"message\":\"Invalid API key\",\"type\":\"invalid_request_error\",\"code\":\"invalid_api_key\"}}"
        return Response(
            status: .unauthorized,
            headers: jsonHeaders(),
            body: .init(byteBuffer: ByteBuffer(string: errorPayload))
        )
    }
}
