// MetricsHandler.swift — Prometheus metrics and model list endpoints

import Foundation
import HTTPTypes
import Hummingbird
import MLX
import MLXLLM

// MARK: - Prometheus Metrics

func handleMetrics(
    isSSDStream: Bool,
    stats: ServerStats
) async -> Response {
    let activeMemBytes = Memory.activeMemory
    let peakMemBytes = Memory.peakMemory
    let cacheMemBytes = Memory.cacheMemory
    let snapshot = await stats.snapshot()
    let uptime = snapshot.uptimeSeconds
    var lines: [String] = []
    lines.append("# HELP swiftlm_requests_total Total requests processed")
    lines.append("# TYPE swiftlm_requests_total counter")
    lines.append("swiftlm_requests_total \(snapshot.requestsTotal)")
    lines.append("# HELP swiftlm_requests_active Currently active requests")
    lines.append("# TYPE swiftlm_requests_active gauge")
    lines.append("swiftlm_requests_active \(snapshot.requestsActive)")
    lines.append("# HELP swiftlm_tokens_generated_total Total tokens generated")
    lines.append("# TYPE swiftlm_tokens_generated_total counter")
    lines.append("swiftlm_tokens_generated_total \(snapshot.tokensGenerated)")
    lines.append("# HELP swiftlm_tokens_per_second Average token generation rate")
    lines.append("# TYPE swiftlm_tokens_per_second gauge")
    lines.append("swiftlm_tokens_per_second \(String(format: "%.2f", snapshot.avgTokensPerSec))")
    lines.append("# HELP swiftlm_memory_active_bytes Active GPU memory usage")
    lines.append("# TYPE swiftlm_memory_active_bytes gauge")
    lines.append("swiftlm_memory_active_bytes \(activeMemBytes)")
    lines.append("# HELP swiftlm_memory_peak_bytes Peak GPU memory usage")
    lines.append("# TYPE swiftlm_memory_peak_bytes gauge")
    lines.append("swiftlm_memory_peak_bytes \(peakMemBytes)")
    lines.append("# HELP swiftlm_memory_cache_bytes Cached GPU memory")
    lines.append("# TYPE swiftlm_memory_cache_bytes gauge")
    lines.append("swiftlm_memory_cache_bytes \(cacheMemBytes)")
    lines.append("# HELP swiftlm_uptime_seconds Server uptime")
    lines.append("# TYPE swiftlm_uptime_seconds gauge")
    lines.append("swiftlm_uptime_seconds \(String(format: "%.0f", uptime))")

    // SSD Flash-Stream metrics (only emitted when --stream-experts is active)
    if isSSDStream {
        let ssd = MLXFast.ssdMetricsSnapshot()
        lines.append("# HELP swiftlm_ssd_throughput_mbps NVMe read throughput (10 s rolling average, MB/s)")
        lines.append("# TYPE swiftlm_ssd_throughput_mbps gauge")
        lines.append("swiftlm_ssd_throughput_mbps \(String(format: "%.1f", ssd.throughputMBperS))")
        lines.append("# HELP swiftlm_ssd_bytes_read_total Lifetime bytes read from SSD for expert weights")
        lines.append("# TYPE swiftlm_ssd_bytes_read_total counter")
        lines.append("swiftlm_ssd_bytes_read_total \(ssd.totalBytesRead)")
        lines.append("# HELP swiftlm_ssd_chunks_total Lifetime expert chunks loaded from SSD")
        lines.append("# TYPE swiftlm_ssd_chunks_total counter")
        lines.append("swiftlm_ssd_chunks_total \(ssd.totalChunks)")
        lines.append("# HELP swiftlm_ssd_chunk_latency_ms Average per-chunk SSD read latency (ms, lifetime)")
        lines.append("# TYPE swiftlm_ssd_chunk_latency_ms gauge")
        lines.append("swiftlm_ssd_chunk_latency_ms \(String(format: "%.4f", ssd.avgChunkLatencyMS))")
    }

    lines.append("")
    let metrics = lines.joined(separator: "\n")
    return Response(
        status: .ok,
        headers: HTTPFields([HTTPField(name: .contentType, value: "text/plain; version=0.0.4; charset=utf-8")]),
        body: .init(byteBuffer: ByteBuffer(string: metrics))
    )
}

// MARK: - Model List

func handleModelList(modelId: String) -> Response {
    let payload = """
    {"object":"list","data":[{"id":"\(modelId)","object":"model","created":\(Int(Date().timeIntervalSince1970)),"owned_by":"mlx-community"}]}
    """
    return Response(
        status: .ok,
        headers: jsonHeaders(),
        body: .init(byteBuffer: ByteBuffer(string: payload))
    )
}
