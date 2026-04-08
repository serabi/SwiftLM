/// Calibrator.swift -- Auto-tuning "Wisdom" system for optimal inference config
///
/// MLX's `Memory.cacheLimit` controls how aggressively the GPU page cache is
/// reclaimed. The ideal value depends on the interaction between a specific
/// model's memory footprint and the hardware it runs on -- too tight and decode
/// throughput drops from constant cache thrashing; too loose and the system can
/// OOM or trigger swap pressure that tanks latency. There is no single correct
/// value, so we measure empirically.
///
/// Inspired by FFTW's "wisdom" pattern: the first time a (model, hardware) pair
/// is seen, we run a short benchmark across a handful of cache-limit settings,
/// pick the one that maximizes decode tok/s, and persist the result as JSON in
/// `~/.swiftlm/wisdom/`. On subsequent launches the stored wisdom is loaded
/// instantly -- zero calibration overhead after the first run.
///
/// The calibration itself is lightweight: a single short prompt is decoded at
/// each candidate cache limit, measuring both time-to-first-token (prefill) and
/// steady-state decode throughput. The whole sweep typically takes 10-30 seconds
/// depending on model size.
///
/// Usage:
///   ```swift
///   let wisdom = try await Calibrator.calibrate(container: container, plan: plan, modelId: id)
///   Memory.cacheLimit = wisdom.cacheLimit
///   ```

import Foundation
import MLX
import MLXLMCommon

// MARK: - Wisdom Entry

/// Persisted calibration result for a specific (model, hardware) combination.
///
/// Contains both the optimal configuration (`cacheLimit`) and the performance
/// metrics observed during calibration. The metrics are informational -- they
/// let the user (and logging) compare expected vs actual throughput on future
/// runs to detect regressions or hardware changes that warrant recalibration.
struct WisdomEntry: Codable {
    let modelId: String
    let hardwareFingerprint: String
    let cacheLimit: Int  // bytes
    let gpuLayers: Int?
    let tokPerSec: Double
    let prefillTokPerSec: Double
    let ttftMs: Double
    let memoryPeakMB: Int
    let calibratedAt: Date
    let calibrationSeconds: Double
}

// MARK: - Calibration Config

/// A single calibration trial configuration.
///
/// Each trial pairs a candidate `Memory.cacheLimit` value with a human-readable
/// label used in log output during the calibration sweep.
private struct CalibrationTrial {
    let cacheLimitBytes: Int
    let label: String
}

// MARK: - Calibrator

/// Namespace for the auto-calibration ("Wisdom") system.
///
/// All methods are static; the enum has no cases, preventing accidental
/// instantiation. State lives entirely on disk (`~/.swiftlm/wisdom/`) and in
/// the MLX `Memory` globals that are set as a side effect of calibration.
enum Calibrator {

    /// Directory for persisted wisdom JSON files.
    ///
    /// Stored under the user's home directory so wisdom survives across
    /// SwiftLM updates but remains per-user (important for multi-user macOS).
    private static var wisdomDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".swiftlm/wisdom")
    }
    
    /// Build a hardware fingerprint string: chip + memory + OS version.
    ///
    /// The fingerprint ensures wisdom is invalidated when anything that affects
    /// inference performance changes -- different chip, different RAM capacity,
    /// or an OS update that may alter the Metal driver or unified memory behavior.
    ///
    /// - Returns: A string like `"arm64_32GB_Version 15.2 (Build 24C101)"`.
    static func hardwareFingerprint() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        let memGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(machine)_\(memGB)GB_\(os)"
    }
    
    /// Derive a filesystem-safe key for a (model, hardware) pair.
    ///
    /// Concatenates the model identifier with the hardware fingerprint and
    /// sanitizes characters that are invalid in filenames. The result is used
    /// as the stem of the JSON file stored in `wisdomDirectory`.
    ///
    /// - Parameter modelId: HuggingFace-style model identifier (e.g. `"mlx-community/Llama-3-8B"`).
    /// - Returns: A sanitized string safe for use as a filename stem.
    private static func wisdomKey(modelId: String) -> String {
        let hw = hardwareFingerprint()
        let combined = "\(modelId)_\(hw)"
        // Simple hash: use the string itself, sanitized for filename
        let sanitized = combined
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        return sanitized
    }
    
    /// Load a previously-stored wisdom entry for the given model on this hardware.
    ///
    /// Looks up `~/.swiftlm/wisdom/<key>.json` where the key encodes both the
    /// model identifier and the current hardware fingerprint. Returns `nil` if
    /// no file exists (first run) or if the file is corrupt/unreadable.
    ///
    /// - Parameter modelId: HuggingFace-style model identifier.
    /// - Returns: The deserialized `WisdomEntry`, or `nil` if unavailable.
    /// - Side effects: Reads from disk. Prints a warning on decode failure.
    static func loadWisdom(modelId: String) -> WisdomEntry? {
        let key = wisdomKey(modelId: modelId)
        let path = wisdomDirectory.appendingPathComponent("\(key).json")
        
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WisdomEntry.self, from: data)
        } catch {
            print("[SwiftLM] ⚠️  Failed to load wisdom: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Persist a wisdom entry to `~/.swiftlm/wisdom/<key>.json`.
    ///
    /// Creates the wisdom directory if it does not yet exist. The JSON is
    /// pretty-printed with sorted keys for human readability and stable diffs.
    ///
    /// - Parameter entry: The calibration result to persist.
    /// - Throws: File I/O errors from `FileManager` or `JSONEncoder`.
    /// - Side effects: Creates directories and writes a file to disk.
    private static func saveWisdom(_ entry: WisdomEntry) throws {
        let key = wisdomKey(modelId: entry.modelId)
        let dir = wisdomDirectory
        
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let path = dir.appendingPathComponent("\(key).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        try data.write(to: path)
    }
    
    /// Run the full calibration sweep: benchmark cache limits and pick the fastest.
    ///
    /// Iterates over four candidate `Memory.cacheLimit` values spanning from a
    /// tight budget (just enough for model weights plus headroom) up to unlimited,
    /// runs a short inference at each, and selects the setting that maximizes
    /// decode tok/s. The winning config is applied immediately and persisted.
    ///
    /// - Parameters:
    ///   - container: The loaded `ModelContainer` to benchmark against.
    ///   - plan: The partition plan describing model weight/KV-cache memory needs.
    ///   - modelId: HuggingFace-style model identifier used as the wisdom key.
    ///   - contextSize: Maximum context window (unused in trials today but reserved
    ///     for future KV-cache-aware calibration).
    /// - Returns: The `WisdomEntry` capturing the best configuration and metrics.
    /// - Throws: `CalibratorError.allTrialsFailed` if every trial errors out.
    /// - Side effects: Mutates `Memory.cacheLimit` to the winning value. Writes
    ///   wisdom JSON to `~/.swiftlm/wisdom/`. Prints progress to stdout.
    static func calibrate(
        container: ModelContainer,
        plan: PartitionPlan,
        modelId: String,
        contextSize: Int = 4096
    ) async throws -> WisdomEntry {
        let startTime = Date()
        print("[SwiftLM] 📊 Calibrating... (this only happens once per model × hardware)")
        
        // Determine trial cache limits based on available memory
        let systemRAMBytes = Int(ProcessInfo.processInfo.physicalMemory)
        let modelWeightBytes = Int(plan.weightMemoryGB * 1e9)
        
        // Sweep from tight to unlimited. The range is designed so that:
        // - "tight" tests whether forcing aggressive cache eviction helps (it
        //   can on memory-constrained machines where swap pressure is worse than
        //   re-computation).
        // - "moderate" and "generous" test intermediate points.
        // - "unlimited" (0) lets MLX manage the cache freely -- often best on
        //   machines with ample RAM, but can cause OOM or swap on smaller ones.
        let freeRAMBytes = systemRAMBytes - modelWeightBytes
        let trials: [CalibrationTrial] = [
            CalibrationTrial(
                // 20% headroom above weights: minimal room for KV cache and
                // activations. Forces aggressive eviction -- useful when RAM is
                // scarce and swap latency dominates.
                cacheLimitBytes: modelWeightBytes + modelWeightBytes / 5,
                label: "tight (weights + 20%)"
            ),
            CalibrationTrial(
                // 25% of free RAM on top of weights: a moderate budget that
                // balances cache reuse against leaving room for the OS and other
                // processes.
                cacheLimitBytes: modelWeightBytes + freeRAMBytes / 4,
                label: "moderate (weights + 25% free)"
            ),
            CalibrationTrial(
                // 50% of free RAM on top of weights: generous but still leaves
                // headroom so the system does not start paging during decode.
                cacheLimitBytes: modelWeightBytes + freeRAMBytes / 2,
                label: "generous (weights + 50% free)"
            ),
            CalibrationTrial(
                // 0 means "no limit" -- MLX manages the cache with no cap.
                // Best when the model fits comfortably in RAM.
                cacheLimitBytes: 0,
                label: "unlimited (system default)"
            ),
        ]
        
        var bestTrial: (trial: CalibrationTrial, tokPerSec: Double, prefillTokPerSec: Double, ttft: Double)?
        
        // A short, deterministic prompt that produces enough tokens to reach
        // steady-state decode without dominating calibration wall-clock time.
        let calibrationPrompt = "Explain the concept of machine learning in three sentences."
        // 30 tokens is the sweet spot: the first ~5 tokens are noisy (pipeline
        // warmup), so we need at least 20+ steady-state tokens for a stable
        // tok/s measurement, but going much higher wastes calibration time
        // across 4 trials (each additional token adds ~30-80ms depending on
        // model size).
        let maxTokens = 30
        
        for (idx, trial) in trials.enumerated() {
            print("[SwiftLM]   Trial \(idx + 1)/\(trials.count): \(trial.label) (\(trial.cacheLimitBytes / (1024*1024))MB)")
            
            // Set cache limit for this trial
            if trial.cacheLimitBytes > 0 {
                Memory.cacheLimit = trial.cacheLimitBytes
            } else {
                // Reset to system default
                Memory.cacheLimit = 0
            }
            
            // Run inference and measure
            let result = await measureInference(
                container: container,
                prompt: calibrationPrompt,
                maxTokens: maxTokens
            )
            
            if let result = result {
                print("[SwiftLM]     → \(String(format: "%.1f", result.tokPerSec)) tok/s decode, \(String(format: "%.0f", result.ttftMs))ms TTFT")
                
                if bestTrial == nil || result.tokPerSec > bestTrial!.tokPerSec {
                    bestTrial = (trial, result.tokPerSec, result.prefillTokPerSec, result.ttftMs)
                }
            } else {
                print("[SwiftLM]     → failed, skipping")
            }
        }
        
        guard let best = bestTrial else {
            throw CalibratorError.allTrialsFailed
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        // Apply the winner
        if best.trial.cacheLimitBytes > 0 {
            Memory.cacheLimit = best.trial.cacheLimitBytes
        }
        
        let entry = WisdomEntry(
            modelId: modelId,
            hardwareFingerprint: hardwareFingerprint(),
            cacheLimit: best.trial.cacheLimitBytes,
            gpuLayers: plan.gpuLayers,
            tokPerSec: best.tokPerSec,
            prefillTokPerSec: best.prefillTokPerSec,
            ttftMs: best.ttft,
            // GPU.activeMemory is sampled after all trials; it reflects the
            // high-water mark of the winning trial's memory usage.
            memoryPeakMB: Int(Double(GPU.activeMemory) / 1e6),
            calibratedAt: Date(),
            calibrationSeconds: elapsed
        )
        
        try saveWisdom(entry)
        
        print("[SwiftLM] 📊 Calibration complete in \(String(format: "%.1f", elapsed))s")
        print("[SwiftLM]    Winner: \(best.trial.label) → \(String(format: "%.1f", best.tokPerSec)) tok/s")
        print("[SwiftLM]    Saved to ~/.swiftlm/wisdom/")
        
        return entry
    }
    
    /// Run a single inference pass and measure throughput metrics.
    ///
    /// Prepares the prompt as a chat message (matching `Server.swift`'s input
    /// path so the benchmark exercises the same code), generates up to
    /// `maxTokens` tokens, and times both prefill (time-to-first-token) and
    /// decode (subsequent tokens).
    ///
    /// - Parameters:
    ///   - container: The model container to run inference against.
    ///   - prompt: The text prompt to send as a user chat message.
    ///   - maxTokens: Maximum number of tokens to generate before stopping.
    /// - Returns: An `InferenceResult` with timing metrics, or `nil` if inference
    ///   threw an error (the caller logs this and moves to the next trial).
    private static func measureInference(
        container: ModelContainer,
        prompt: String,
        maxTokens: Int
    ) async -> InferenceResult? {
        do {
            // Prepare input using the same pattern as Server.swift
            let chatMessages: [Chat.Message] = [.user(prompt)]
            let userInput = UserInput(chat: chatMessages)
            let lmInput = try await container.prepare(input: userInput)
            let inputTokenCount = lmInput.text.tokens.size
            
            let result: InferenceResult = try await container.perform { context in
                // 0.6 adds slight randomness so we do not hit degenerate
                // repetition loops that could skew timing, while staying low
                // enough that output length is predictable across trials.
                let generateParams = GenerateParameters(temperature: 0.6)
                
                let ttftStart = Date()
                var firstTokenTime: Date?
                var tokenCount = 0
                
                for try await result in try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: generateParams,
                    context: context
                ) {
                    switch result {
                    case .chunk(_, tokenId: _):
                        if firstTokenTime == nil {
                            firstTokenTime = Date()
                        }
                        tokenCount += 1
                        if tokenCount >= maxTokens {
                            break
                        }
                    default:
                        break
                    }
                    if tokenCount >= maxTokens { break }
                }
                
                let ttft = firstTokenTime?.timeIntervalSince(ttftStart) ?? 0
                let decodeTime = Date().timeIntervalSince(firstTokenTime ?? ttftStart)
                // tokenCount - 1 because the first decoded token's latency is
                // part of TTFT (prefill), not steady-state decode throughput.
                let tokPerSec = decodeTime > 0 && tokenCount > 1 ? Double(tokenCount - 1) / decodeTime : 0
                let prefillTokPerSec = ttft > 0 ? Double(inputTokenCount) / ttft : 0
                
                return InferenceResult(
                    tokPerSec: tokPerSec,
                    prefillTokPerSec: prefillTokPerSec,
                    ttftMs: ttft * 1000,
                    tokenCount: tokenCount
                )
            }
            
            return result
        } catch {
            return nil
        }
    }
}

// MARK: - Supporting Types

/// Intermediate measurement from a single calibration trial.
///
/// Not persisted -- only used to compare trials within a single calibration
/// sweep. The winning trial's values are copied into the `WisdomEntry`.
private struct InferenceResult {
    let tokPerSec: Double
    let prefillTokPerSec: Double
    let ttftMs: Double
    let tokenCount: Int
}

/// Errors specific to the calibration process.
enum CalibratorError: Error {
    /// Every cache-limit trial errored during inference, so no winner could be
    /// selected. This typically indicates a model loading or Metal issue rather
    /// than a cache-limit problem.
    case allTrialsFailed
}
