// HealthHandler.swift — /health endpoint with Codable response

import Foundation
import HTTPTypes
import Hummingbird
import MLX

// MARK: - Health Response Types

struct HealthResponse: Encodable {
    let status: String
    let model: String
    let vision: Bool
    let memory: MemoryInfo
    let stats: StatsInfo
    let partition: PartitionInfo?
}

struct MemoryInfo: Encodable {
    let activeMb: Int
    let peakMb: Int
    let cacheMb: Int
    let totalSystemMb: Int
    let gpuArchitecture: String

    enum CodingKeys: String, CodingKey {
        case activeMb = "active_mb"
        case peakMb = "peak_mb"
        case cacheMb = "cache_mb"
        case totalSystemMb = "total_system_mb"
        case gpuArchitecture = "gpu_architecture"
    }
}

struct StatsInfo: Encodable {
    let requestsTotal: Int
    let requestsActive: Int
    let tokensGenerated: Int
    let avgTokensPerSec: String

    enum CodingKeys: String, CodingKey {
        case requestsTotal = "requests_total"
        case requestsActive = "requests_active"
        case tokensGenerated = "tokens_generated"
        case avgTokensPerSec = "avg_tokens_per_sec"
    }
}

struct PartitionInfo: Encodable {
    let strategy: String
    let overcommitRatio: Double
    let modelWeightGb: Double
    let kvCacheGb: Double
    let totalRequiredGb: Double
    let gpuLayers: Int
    let cpuLayers: Int
    let totalLayers: Int
    let estimatedTokS: Double
    let ssdStream: Bool

    enum CodingKeys: String, CodingKey {
        case strategy
        case overcommitRatio = "overcommit_ratio"
        case modelWeightGb = "model_weight_gb"
        case kvCacheGb = "kv_cache_gb"
        case totalRequiredGb = "total_required_gb"
        case gpuLayers = "gpu_layers"
        case cpuLayers = "cpu_layers"
        case totalLayers = "total_layers"
        case estimatedTokS = "estimated_tok_s"
        case ssdStream = "ssd_stream"
    }
}

// MARK: - Handler

func handleHealth(
    modelId: String,
    isVision: Bool,
    partitionPlan: PartitionPlan?,
    isSSDStream: Bool,
    stats: ServerStats
) async -> Response {
    let activeMemMB = Memory.activeMemory / (1024 * 1024)
    let peakMemMB = Memory.peakMemory / (1024 * 1024)
    let cacheMemMB = Memory.cacheMemory / (1024 * 1024)
    let deviceInfo = GPU.deviceInfo()
    let totalMemMB = deviceInfo.memorySize / (1024 * 1024)
    let snapshot = await stats.snapshot()

    var partitionInfo: PartitionInfo? = nil
    if let plan = partitionPlan {
        let isSSD = isSSDStream
        let estimatedTokS: Double
        if isSSD {
            estimatedTokS = round(max(plan.estimatedTokensPerSec, plan.estimatedTokensPerSec * plan.overcommitRatio) * 10) / 10
        } else {
            estimatedTokS = round(plan.estimatedTokensPerSec * 10) / 10
        }
        partitionInfo = PartitionInfo(
            strategy: isSSD ? "ssd_streaming" : plan.strategy.rawValue,
            overcommitRatio: round(plan.overcommitRatio * 100) / 100,
            modelWeightGb: round(plan.weightMemoryGB * 10) / 10,
            kvCacheGb: round(plan.kvCacheMemoryGB * 10) / 10,
            totalRequiredGb: round(plan.totalRequiredGB * 10) / 10,
            gpuLayers: isSSD ? plan.totalLayers : plan.gpuLayers,
            cpuLayers: isSSD ? 0 : (plan.totalLayers - plan.gpuLayers),
            totalLayers: plan.totalLayers,
            estimatedTokS: estimatedTokS,
            ssdStream: isSSD
        )
    }

    let response = HealthResponse(
        status: "ok",
        model: modelId,
        vision: isVision,
        memory: MemoryInfo(
            activeMb: activeMemMB,
            peakMb: peakMemMB,
            cacheMb: cacheMemMB,
            totalSystemMb: totalMemMB,
            gpuArchitecture: deviceInfo.architecture
        ),
        stats: StatsInfo(
            requestsTotal: snapshot.requestsTotal,
            requestsActive: snapshot.requestsActive,
            tokensGenerated: snapshot.tokensGenerated,
            avgTokensPerSec: String(format: "%.2f", snapshot.avgTokensPerSec)
        ),
        partition: partitionInfo
    )

    do {
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        return Response(
            status: .ok,
            headers: jsonHeaders(),
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    } catch {
        let fallback = "{\"status\":\"ok\",\"model\":\"\(modelId)\"}"
        return Response(
            status: .ok,
            headers: jsonHeaders(),
            body: .init(byteBuffer: ByteBuffer(string: fallback))
        )
    }
}
