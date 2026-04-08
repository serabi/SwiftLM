import Foundation

// ── Server Config ────────────────────────────────────────────────────────────

struct ServerConfig: Sendable {
    let modelId: String
    let maxTokens: Int
    let ctxSize: Int?
    let temp: Float
    let topP: Float
    let repeatPenalty: Float?
    let thinking: Bool
    let isVision: Bool
    let prefillSize: Int
    /// When true, each KVCacheSimple layer compresses history > 8192 tokens to 3-bit PolarQuant.
    let turboKV: Bool
}

// ── Server Stats Tracker ───────────────────────────────────────────────────────

actor ServerStats {
    private var requestsTotal: Int = 0
    private var requestsActive: Int = 0
    private var tokensGenerated: Int = 0
    private var totalGenerationTimeSeconds: Double = 0
    private let startTime = Date()

    struct Snapshot: Sendable {
        let requestsTotal: Int
        let requestsActive: Int
        let tokensGenerated: Int
        let avgTokensPerSec: Double
        let uptimeSeconds: TimeInterval
    }

    func requestStarted() {
        requestsTotal += 1
        requestsActive += 1
    }

    func requestFinished(tokens: Int, duration: TimeInterval) {
        requestsActive -= 1
        tokensGenerated += tokens
        totalGenerationTimeSeconds += duration
    }

    func snapshot() -> Snapshot {
        let tps = totalGenerationTimeSeconds > 0 ? Double(tokensGenerated) / totalGenerationTimeSeconds : 0
        return Snapshot(
            requestsTotal: requestsTotal,
            requestsActive: requestsActive,
            tokensGenerated: tokensGenerated,
            avgTokensPerSec: tps,
            uptimeSeconds: Date().timeIntervalSince(startTime)
        )
    }
}
