// ServerBootstrap.swift -- Model loading, memory configuration, and server startup
//
// Handles: model download/load, SSD streaming activation, memory strategy,
// GPU layer partitioning, Wisdom calibration, and Hummingbird server lifecycle.

import ArgumentParser
import Foundation
import Hummingbird
import Hub
import Logging
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

struct ServerBootstrap {

    static func start(options: MLXServer) async throws {
        Log.info("Loading model: \(options.model)")
        let modelId = options.model

        // Load model
        var modelConfig: ModelConfiguration
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: modelId) {
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: modelId, isDirectory: &isDir)
            if isDir.boolValue {
                Log.info("Loading from local directory: \(modelId)")
                modelConfig = ModelConfiguration(directory: URL(filePath: modelId))
            } else {
                modelConfig = ModelConfiguration(id: modelId)
            }
        } else {
            modelConfig = ModelConfiguration(id: modelId)
        }

        // Inject streaming flag into config to bypass model loading if requested
        if options.streamExperts {
            modelConfig.lazyLoad = true
        }

        // Pre-load profiling
        let modelDirectory = resolveModelDirectory(modelId: modelId)

        if options.streamExperts, let modelDir = modelDirectory {
            setenv("EXPERIMENTAL_SSD_STREAM", modelDir.path, 1)
            ExpertStreamingConfig.shared.activate(
                modelDirectory: modelDir,
                useDirectIO: true
            )
            setenv("MLX_MAX_OPS_PER_BUFFER", "50", 1)
            Log.info("Enabled Async SSD Streaming on directory: \(modelDir.lastPathComponent)")
        }

        var partitionPlan: PartitionPlan?
        if let modelDir = modelDirectory,
           let profile = ModelProfiler.profile(modelDirectory: modelDir, modelId: modelId) {
            let system = ModelProfiler.systemProfile()
            let contextSize = options.ctxSize ?? 4096
            let plan = ModelProfiler.plan(model: profile, system: system, contextSize: contextSize)
            partitionPlan = plan

            // --info mode: print report and exit
            if options.info {
                ModelProfiler.printReport(plan: plan, model: profile, system: system)
                return
            }

            // Apply memory strategy
            switch plan.strategy {
            case .fullGPU:
                Log.info("Memory strategy: FULL GPU (\(String(format: "%.1f", plan.weightMemoryGB))GB model, \(String(format: "%.1f", system.availableRAMGB))GB available)")
            case .swapAssisted:
                if options.streamExperts {
                    let physicalBudget = Int(Double(system.totalRAMBytes) * 0.85) - (4 * 1024 * 1024 * 1024)
                    Memory.cacheLimit = physicalBudget
                    Memory.memoryLimit = 200 * 1024 * 1024 * 1024
                    Log.info("Memory strategy: SSD STREAMING (page-cache managed, \(physicalBudget / (1024*1024*1024))GB RAM budget, no swap)")
                } else {
                    Memory.cacheLimit = plan.recommendedCacheLimit
                    Log.info("Memory strategy: SWAP-ASSISTED (\(String(format: "%.1f", plan.overcommitRatio))x overcommit, cache limited to \(plan.recommendedCacheLimit / (1024*1024))MB)")
                    for w in plan.warnings { Log.info("   \(w)") }
                }
            case .layerPartitioned:
                if options.streamExperts {
                    let physicalBudget = Int(Double(system.totalRAMBytes) * 0.85) - (4 * 1024 * 1024 * 1024)
                    Memory.cacheLimit = physicalBudget
                    Memory.memoryLimit = 200 * 1024 * 1024 * 1024
                    Log.info("Memory strategy: SSD STREAMING (page-cache managed, \(physicalBudget / (1024*1024*1024))GB RAM budget, no swap)")
                } else {
                    Memory.cacheLimit = plan.recommendedCacheLimit
                    Log.info("Memory strategy: LAYER PARTITIONED (\(plan.recommendedGPULayers)/\(plan.totalLayers) GPU layers, cache limited to \(plan.recommendedCacheLimit / (1024*1024))MB)")
                    for w in plan.warnings { Log.info("   \(w)") }
                }
            case .tooLarge:
                Memory.cacheLimit = plan.recommendedCacheLimit
                Log.warning("Model is \(String(format: "%.1f", plan.overcommitRatio))x system RAM. Loading will be extremely slow.")
                for w in plan.warnings { Log.warning("   \(w)") }
            }
        } else if options.info {
            Log.info("Model not yet downloaded. Run without --info to download first, or provide a local path.")
            return
        }

        // Determine GPU layer count
        var requestedGPULayers: Int? = nil
        if let gpuLayersArg = options.gpuLayers {
            if gpuLayersArg == "auto" {
                requestedGPULayers = partitionPlan?.recommendedGPULayers
                Log.info("--gpu-layers auto -> \(requestedGPULayers.map(String.init) ?? "all") layers on GPU")
            } else if let n = Int(gpuLayersArg) {
                requestedGPULayers = n
                Log.info("--gpu-layers \(n) -> \(n) layers on GPU")
            } else {
                Log.warning("--gpu-layers must be 'auto' or an integer, got '\(gpuLayersArg)'. Using all GPU.")
            }
        } else if let plan = partitionPlan,
                  (plan.strategy == .layerPartitioned || plan.strategy == .swapAssisted),
                  plan.overcommitRatio > 1.0 {
            if options.streamExperts {
                Log.info("SSD Streaming active: Bypassing CPU auto-partitioning (forcing all layers to GPU)")
                partitionPlan?.gpuLayers = plan.totalLayers
            } else {
                requestedGPULayers = plan.recommendedGPULayers
                Log.info("Auto-partitioning: \(plan.recommendedGPULayers)/\(plan.totalLayers) layers on GPU")
            }
        }

        let isVision = options.vision
        let container: ModelContainer

        let resolvedModelId: String = {
            if case .id(let idStr, _) = modelConfig.id { return idStr }
            return options.model
        }()
        let tracker = ProgressTracker(modelId: resolvedModelId)

        let cacheRoot = URL.applicationSupportDirectory
            .appendingPathComponent("MLX", isDirectory: true)
            .appendingPathComponent("HuggingFace", isDirectory: true)
        if isVision {
            Log.info("Loading VLM (vision-language model)...")
            let downloader = HubDownloader(hub: HubApi(downloadBase: cacheRoot))
            container = try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: TransformersTokenizerLoader(),
                configuration: modelConfig
            ) { progress in
                tracker.printProgress(progress)
            }
        } else {
            let downloader = HubDownloader(hub: HubApi(downloadBase: cacheRoot))
            container = try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: TransformersTokenizerLoader(),
                configuration: modelConfig
            ) { progress in
                tracker.printProgress(progress)
            }
        }

        Log.info("Loaded model configuration. Inferred tool call format: \(String(describing: await container.configuration.toolCallFormat))")

        // Apply GPU/CPU layer partitioning
        if let gpuCount = requestedGPULayers {
            let actual = await container.setGPULayers(gpuCount)
            if let actual {
                let total = partitionPlan?.totalLayers ?? actual
                let cpuCount = total - actual
                Log.info("Layer split active: \(actual) GPU / \(cpuCount) CPU")
                partitionPlan?.gpuLayers = actual
            } else {
                Log.warning("Model does not support layer partitioning (architecture not yet adapted)")
            }
        }

        // Apply SSD Expert Streaming
        if options.streamExperts {
            let streamingEnabled = await container.setStreamExperts(true)
            if streamingEnabled {
                Log.info("SSD Expert Streaming enabled (lazy load + layer-sync)")
            } else {
                Log.warning("Model does not support SSD expert streaming")
            }
        }

        // Auto-calibration (Wisdom system)
        if let plan = partitionPlan, !options.streamExperts {
            if options.calibrate {
                if let wisdom = try? await Calibrator.calibrate(
                    container: container, plan: plan, modelId: modelId,
                    contextSize: options.ctxSize ?? 4096
                ) {
                    Memory.cacheLimit = wisdom.cacheLimit
                }
            } else if let wisdom = Calibrator.loadWisdom(modelId: modelId) {
                if wisdom.cacheLimit > 0 {
                    Memory.cacheLimit = wisdom.cacheLimit
                }
                Log.info("Loaded wisdom: \(String(format: "%.1f", wisdom.tokPerSec)) tok/s, cache=\(wisdom.cacheLimit / (1024*1024))MB (calibrated \(wisdom.calibratedAt.formatted(.relative(presentation: .named))))")
            }
        } else if options.streamExperts {
            Log.info("Auto-calibration (Wisdom) bypassed for SSD Streaming")
        }

        Log.info("Model loaded. Starting HTTP server on \(options.host):\(options.port)")

        // Capture CLI defaults into a shared config
        let config = ServerConfig(
            modelId: modelId,
            maxTokens: options.maxTokens,
            ctxSize: options.ctxSize,
            temp: options.temp,
            topP: options.topP,
            repeatPenalty: options.repeatPenalty,
            thinking: options.thinking,
            isVision: isVision,
            prefillSize: options.prefillSize,
            turboKV: options.turboKV
        )

        let parallelSlots = options.parallel
        let corsOrigin = options.cors
        let apiKeyValue = options.apiKey

        // Memory limit enforcement (overrides wisdom)
        if let memLimitMB = options.memLimit {
            let bytes = memLimitMB * 1024 * 1024
            Memory.memoryLimit = bytes
            Memory.cacheLimit = bytes
            Log.info("Memory limit set to \(memLimitMB)MB (overrides wisdom)")
        }

        // Concurrency limiter
        let semaphore = AsyncSemaphore(limit: parallelSlots)

        // Server stats tracker
        let stats = ServerStats()

        let ctxSizeStr = config.ctxSize.map { String($0) } ?? "model_default"
        let penaltyStr = config.repeatPenalty.map { String($0) } ?? "disabled"
        let corsStr = corsOrigin ?? "disabled"
        let memLimitStr = options.memLimit.map { "\($0)MB" } ?? "system_default"
        let authStr = apiKeyValue != nil ? "enabled" : "disabled"
        let thinkingStr = config.thinking ? "enabled" : "disabled"
        let ssdStr = options.streamExperts ? "enabled" : "disabled"
        let turboKVStr = config.turboKV ? "enabled" : "disabled"
        Log.info("Config: ctx_size=\(ctxSizeStr), temp=\(config.temp), top_p=\(config.topP), repeat_penalty=\(penaltyStr), parallel=\(parallelSlots), cors=\(corsStr), mem_limit=\(memLimitStr), auth=\(authStr), thinking=\(thinkingStr), ssd_stream=\(ssdStr), turbo_kv=\(turboKVStr)")

        // Build router
        let promptCache = PromptCache()
        let isSSDStream = options.streamExperts
        let router = buildRouter(
            config: config,
            container: container,
            semaphore: semaphore,
            stats: stats,
            promptCache: promptCache,
            partitionPlan: partitionPlan,
            isSSDStream: isSSDStream,
            corsOrigin: corsOrigin,
            apiKey: apiKeyValue
        )

        // Start server
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(options.host, port: options.port))
        )

        Log.info("Ready. Listening on http://\(options.host):\(options.port)")

        // Emit machine-readable ready event for Aegis integration
        var readyEvent: [String: Any] = [
            "event": "ready",
            "port": options.port,
            "model": modelId,
            "engine": "mlx",
            "vision": isVision
        ]
        if let plan = partitionPlan {
            var info = plan.healthInfo
            if options.streamExperts {
                info["strategy"] = "ssd_streaming"
                info["ssd_stream"] = true
                let ssdEstimate = max(plan.estimatedTokensPerSec, plan.estimatedTokensPerSec * plan.overcommitRatio)
                info["estimated_tok_s"] = round(ssdEstimate * 10) / 10
                info["gpu_layers"] = plan.totalLayers
                info["cpu_layers"] = 0
            }
            readyEvent["partition"] = info
        }
        if let data = try? JSONSerialization.data(withJSONObject: readyEvent),
           let json = String(data: data, encoding: .utf8) {
            print(json)
            fflush(stdout)
        }

        // Graceful shutdown on SIGTERM/SIGINT
        let shutdownSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        shutdownSource.setEventHandler {
            print("\n[SwiftLM] Received SIGTERM, shutting down gracefully...")
            Darwin.exit(0)
        }
        interruptSource.setEventHandler {
            print("\n[SwiftLM] Received SIGINT, shutting down gracefully...")
            Darwin.exit(0)
        }
        shutdownSource.resume()
        interruptSource.resume()

        try await app.runService()
    }
}
