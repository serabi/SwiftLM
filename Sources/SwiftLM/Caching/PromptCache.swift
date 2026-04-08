import Foundation
import MLX
import MLXLMCommon

// MARK: - Prompt Cache

actor PromptCache {
    struct CachedState {
        let tokens: [Int]            // Full token sequence that generated this KV state
        let states: [[MLXArray]]     // Per-layer KV state arrays
        let metaStates: [[String]]   // Per-layer metadata
    }

    private var cached: CachedState?
    private var hits: Int = 0
    private var misses: Int = 0

    /// Save the full prompt token sequence and its KV state.
    /// IMPORTANT: We must eval() the state arrays immediately. The state getter may
    /// produce lazy computation graphs (e.g. TurboKV decode -> reshape -> concatenate).
    /// If not materialized now, those lazy references point to the live cache tensors
    /// which get overwritten by subsequent requests, causing stale data / SIGTRAP on restore.
    func save(tokens: [Int], cache: [KVCache]) {
        let states = cache.map { $0.state }
        let metaStates = cache.map { $0.metaState }
        // Materialize all lazy MLX arrays so they survive cache mutations
        let allArrays = states.flatMap { $0 }
        if !allArrays.isEmpty {
            eval(allArrays)
        }
        cached = CachedState(tokens: tokens, states: states, metaStates: metaStates)
    }

    /// Find the longest common prefix between `newTokens` and the cached sequence.
    /// Restores matched KV state, trims any excess — mirrors llama-server behaviour.
    /// Returns the number of matched tokens, or nil on a complete miss.
    func restore(newTokens: [Int], into cache: [KVCache]) -> Int? {
        guard let cached, !cached.tokens.isEmpty else {
            misses += 1
            return nil
        }
        // Token-by-token longest common prefix scan
        var matchLen = 0
        for (a, b) in zip(cached.tokens, newTokens) {
            guard a == b else { break }
            matchLen += 1
        }
        guard matchLen > 0 else {
            misses += 1
            return nil
        }
        // Pre-flight safety check: compute the minimum sequence length across
        // all cached layers. Sliding-window layers (RotatingKVCache) store far
        // fewer tokens than the full prompt (e.g. 1440 vs 5537). If the trim
        // would zero-out any layer, bail BEFORE touching the live cache.
        let excess = cached.tokens.count - matchLen
        if excess > 0 {
            // The state getter stores keys as the first element: [B, H, T, D]
            // dim(2) = T = the number of cached tokens for that layer.
            let minCachedSeqLen = cached.states.map { arrays -> Int in
                guard let firstArray = arrays.first else { return 0 }
                return firstArray.dim(2)  // T dimension
            }.min() ?? 0
            if excess >= minCachedSeqLen {
                // Trim would empty or corrupt at least one layer -> treat as miss
                misses += 1
                return nil
            }
        }
        // Safe to restore: trim won't corrupt any layer
        for i in 0..<min(cache.count, cached.states.count) {
            var layer = cache[i]
            layer.state = cached.states[i]
            layer.metaState = cached.metaStates[i]
        }
        if excess > 0 {
            for layer in cache { layer.trim(excess) }
        }
        hits += 1
        print("[SwiftLM] \u{1F5C2} Prompt cache HIT: \(matchLen)/\(newTokens.count) tokens reused (\(excess > 0 ? "partial" : "full") match)")
        return matchLen
    }

    func stats() -> (hits: Int, misses: Int) { (hits, misses) }
}
