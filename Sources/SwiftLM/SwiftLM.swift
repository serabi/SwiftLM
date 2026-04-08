// SwiftLM.swift -- CLI entry point
//
// OpenAI-compatible LLM server powered by Apple MLX.
// Usage: SwiftLM --model mlx-community/Qwen2.5-3B-Instruct-4bit --port 5413

import ArgumentParser
import Logging

@main
struct MLXServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "SwiftLM",
        abstract: "OpenAI-compatible LLM server powered by Apple MLX"
    )

    @Option(name: .long, help: "HuggingFace model ID or local path")
    var model: String

    @Option(name: .long, help: "Port to listen on")
    var port: Int = 5413

    @Option(name: .long, help: "Host to bind")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Max tokens to generate per request (default)")
    var maxTokens: Int = 2048

    @Option(name: .long, help: "Context window size (KV cache). When set, uses sliding window cache")
    var ctxSize: Int?

    @Option(name: .long, help: "Default sampling temperature (0 = greedy, overridable per-request)")
    var temp: Float = 0.6

    @Option(name: .long, help: "Default top-p nucleus sampling (overridable per-request)")
    var topP: Float = 1.0

    @Option(name: .long, help: "Repetition penalty factor (overridable per-request)")
    var repeatPenalty: Float?

    @Option(name: .long, help: "Number of parallel request slots")
    var parallel: Int = 1

    @Flag(name: .long, help: "Enable thinking/reasoning mode (Qwen3.5 etc). Default: disabled")
    var thinking: Bool = false

    @Flag(name: .long, help: "Enable VLM (vision-language model) mode for image inputs")
    var vision: Bool = false

    @Option(name: .long, help: "GPU memory limit in MB (default: system limit)")
    var memLimit: Int?

    @Option(name: .long, help: "API key for bearer token authentication")
    var apiKey: String?

    @Flag(name: .long, help: "Profile model memory requirements and exit (dry-run)")
    var info: Bool = false

    @Option(name: .long, help: "Number of layers to run on GPU (\"auto\" or integer, default: auto)")
    var gpuLayers: String?

    @Option(name: .long, help: "Allowed CORS origin (* for all, or a specific origin URL)")
    var cors: String?

    @Flag(name: .long, help: "Force re-calibration of optimal memory settings (normally auto-cached)")
    var calibrate: Bool = false

    @Flag(name: .long, help: "Enable SSD expert streaming for MoE models (Flash-MoE style memory-mapping)")
    var streamExperts: Bool = false

    @Flag(name: .long, help: "Enable TurboQuant KV-cache compression (3-bit PolarQuant+QJL). Compresses KV history > 8192 tokens to ~3.5 bits/token. Default: disabled")
    var turboKV: Bool = false

    @Option(name: .long, help: "Chunk size for prefill evaluation (default: 512, lower to prevent GPU timeout on large models)")
    var prefillSize: Int = 512

    mutating func run() async throws {
        Log.bootstrap()
        try await ServerBootstrap.start(options: self)
    }
}
