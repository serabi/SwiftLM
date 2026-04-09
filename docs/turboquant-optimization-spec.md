# Feature Spec: TurboQuant KV Cache Performance Optimization

## Problem

TurboQuant's 3-bit PolarQuant KV cache compression saves significant memory at long context but causes catastrophic speed regression:

| Config | 512 tokens | 40K tokens | 100K tokens |
|---|---|---|---|
| Dense/Vanilla | 31.6 tok/s | 19.8 tok/s | 14.8 tok/s |
| TurboQuant | 17.6 tok/s | 5.6 tok/s | 3.7 tok/s |
| **Slowdown** | **1.8x** | **3.5x** | **4.0x** |

Memory savings at 40K: ~10GB GPU allocated reduction. But the speed cost makes it impractical for interactive use.

Benchmark: Gemma 4 26B MoE (4-bit) on M3 Max 36GB.

---

## Root Cause

Every generated token triggers **full decompression of the entire compressed KV history**, scaling linearly with context length.

### The hot path (`AttentionUtils.swift:159-177`)

```swift
if let pk = kvCache.polarKeys, kvCache.compressedOffset > 0 {
    let historyK = MLXFast.turboDecodeK(packed: pk)  // decode ALL compressed keys
    let historyV = MLXFast.turboDecodeV(packed: pv)  // decode ALL compressed values
    fullKeys   = concatenated([mergedK, cachedKeys], axis: 2)
    fullValues = concatenated([mergedV, cachedValues], axis: 2)
}
```

At 40K context with 256-token hot window:
- ~39,744 compressed tokens decoded to fp16 **per generated token**
- Decode output: ~39K tokens x nKVHeads x headDim x 2 bytes = multiple GB of transient fp16 data
- This transient data is discarded after each SDPA call and regenerated for the next token

The decode cost scales O(compressed_tokens) per generation step, explaining the linear slowdown with context length.

### Why the existing QuantizedKVCache doesn't have this problem

`QuantizedKVCache` (KVCache.swift:886) uses `quantizedScaledDotProductAttention()` which computes attention **directly on quantized data** via a fused kernel — no decompression step. TurboQuant instead uses the standard SDPA path after a full decompress, making it fundamentally slower.

---

## Optimization Approaches

### Approach 1: Persistent decode cache (quick win)

**Idea:** Keep the decompressed fp16 history across token steps instead of discarding it. Only decode the newly compressed chunk (256 tokens) each eviction cycle.

**Changes:**
- `KVCacheSimple`: Add `decodedHistoryK: MLXArray?` and `decodedHistoryV: MLXArray?` fields
- On eviction (KVCache.swift:411-452): After compressing new cold tokens, decode only the new chunk and concatenate with existing decoded history
- `AttentionUtils.swift:159-177`: Use `decodedHistoryK` directly instead of calling `turboDecodeK` on every token

**Tradeoff:** Memory savings reduced — you keep both the compressed and decompressed versions. At 40K context, compressed history is ~1.5GB (uint8) while decompressed is ~10GB (fp16). Total KV memory goes from ~1.5GB (compressed only) to ~11.5GB (both). Still saves ~5GB vs no compression at all, but the memory benefit is halved.

**Speed impact:** Near-vanilla speed — the per-token cost drops from O(compressed_tokens) to O(1) (just the SDPA on pre-decoded data).

**Effort:** Small. ~30 lines changed in KVCache.swift + AttentionUtils.swift.

**Files:**
- `mlx-swift-lm/Libraries/MLXLMCommon/KVCache.swift` — add decoded cache fields, update eviction logic
- `mlx-swift-lm/Libraries/MLXLMCommon/AttentionUtils.swift:159-177` — use decoded cache
- `mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4.swift:388-399` — same pattern (Gemma4 has its own attention path)

### Approach 2: Fused compressed-attention Metal kernel (highest impact)

**Idea:** Compute attention scores directly on the 3-bit packed representation without decompressing to fp16. Similar to how `quantizedScaledDotProductAttention` operates on the `QuantizedKVCache`'s group-quantized data.

**Changes:**
- New Metal shader: `turbo_scaled_dot_product_attention` that takes packed uint8 polarKeys/polarValues and computes QK^T + softmax + V multiplication in-kernel
- The kernel unpacks 3-bit values to fp16 in registers (not global memory), computes dot products in tiles, and accumulates attention output
- New Swift wrapper: `MLXFast.turboScaledDotProductAttention(queries:, packedKeys:, packedValues:, ...)`
- `AttentionUtils.swift`: Route to fused kernel when TurboQuant is active

**Tradeoff:** No extra memory — compressed representation is the only copy. Full memory savings preserved. Speed would be close to vanilla since decompression happens in GPU registers, not through a separate decode pass.

**Speed impact:** Theoretical near-vanilla speed. The 3-bit unpack per tile is cheap compared to the SDPA math itself.

**Effort:** Large. Requires Metal shader programming, understanding PolarQuant's bit layout, and careful numerical validation. The existing `quantizedScaledDotProductAttention` (KVCache.swift:1691) is a reference for the pattern but uses group quantization, not PolarQuant.

**Files:**
- `.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/` — new Metal shader
- `.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/core/` — new C++ primitive
- `.build/checkouts/mlx-swift/Source/Cmlx/mlx-c/mlx/c/fast.cpp` — C bridge
- `.build/checkouts/mlx-swift/Source/MLX/MLXFast.swift` — Swift API
- `mlx-swift-lm/Libraries/MLXLMCommon/AttentionUtils.swift` — routing logic

### Approach 3: Chunked lazy decompression with attention approximation (medium)

**Idea:** Instead of decoding all compressed history, split it into chunks (e.g., 2048 tokens each). Run a lightweight "attention sketch" on the compressed data to identify which chunks have the highest attention mass, then only decompress those chunks for the full SDPA pass.

**Changes:**
- Split `polarKeys`/`polarValues` into fixed-size chunks during compression
- On each token step: compute approximate attention scores per chunk (e.g., using chunk-level mean key vectors stored alongside the compressed data)
- Only decompress top-K chunks (e.g., top 4 out of 20 for 40K context)
- Run full SDPA on decompressed chunks + hot window

**Tradeoff:** Approximate — attention to low-scoring chunks is dropped. May cause quality degradation for tasks requiring precise long-range recall. Works well for tasks where attention is concentrated in recent context (most coding/chat use cases).

**Speed impact:** Depends on top-K selection. With K=4 chunks of 2048 tokens at 40K context: only decode 8K tokens instead of 39K = ~5x speedup over current TurboQuant.

**Effort:** Medium. Requires chunk metadata storage, approximate scoring logic, and quality validation.

**Files:**
- `mlx-swift-lm/Libraries/MLXLMCommon/KVCache.swift` — chunked storage, metadata
- `mlx-swift-lm/Libraries/MLXLMCommon/AttentionUtils.swift` — chunk selection + partial decode

---

## Recommendation

**Start with Approach 1 (persistent decode cache).** It's a small change that eliminates the per-token decode bottleneck and restores near-vanilla speed. The memory savings are reduced but still meaningful (~5GB at 40K context vs ~10GB today).

Then evaluate whether the reduced memory savings are sufficient for the target use cases:
- If yes: ship it, move on
- If no: invest in Approach 2 (fused kernel) for full memory savings at full speed

Approach 3 (chunked lazy decode) is worth exploring if quality-insensitive workloads dominate, but the approximation makes it risky for general use.

---

## Verification

### Correctness
1. Run the existing prompt cache regression test (Test 2 in `run_benchmark.sh`) with `--turbo-kv` — verify no crashes or shape mismatches
2. Compare model output quality: generate 100 tokens at 8K context with and without TurboQuant, diff the outputs (some divergence expected from quantization, but responses should be coherent)

### Performance
1. Re-run the full benchmark (Test 1) with `gemma-4-26b-a4b-it-4bit` and compare TurboQuant results before/after optimization
2. Target: TurboQuant tok/s within 1.5x of Dense/Vanilla at all context lengths (currently 3.5-4x slower)

### Memory
1. Compare GPU Allocated at 40K and 100K context for TurboQuant before/after
2. For Approach 1: expect ~50% of current TurboQuant memory savings preserved
3. For Approach 2: expect full memory savings preserved

---

## Key files reference

| File | Role |
|---|---|
| `mlx-swift-lm/Libraries/MLXLMCommon/KVCache.swift:315-470` | KVCacheSimple with TurboQuant compression/eviction |
| `mlx-swift-lm/Libraries/MLXLMCommon/AttentionUtils.swift:155-200` | Per-token TurboQuant decode + SDPA (the bottleneck) |
| `mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4.swift:386-400` | Gemma4-specific TurboQuant attention path |
| `mlx-swift-lm/Libraries/MLXLMCommon/KVCache.swift:886+` | QuantizedKVCache (reference for fused approach) |
| `mlx-swift-lm/Libraries/MLXLMCommon/KVCache.swift:1691+` | quantizedScaledDotProductAttention (reference kernel) |
| `.build/checkouts/mlx-swift/Source/MLX/MLXFast.swift` | turboDecodeK/V Swift bindings |
