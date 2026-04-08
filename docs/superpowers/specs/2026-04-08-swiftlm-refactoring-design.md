# SwiftLM Refactoring Design

> Fork: serabi/SwiftLM (from SharpAI/SwiftLM)
> Goal: Clean up vibe-coded inference server for personal use + base for new features (e.g., MCP server on iOS)
> Scope: Both CLI server (SwiftLM) and iOS app (SwiftBuddy) are in play

## Status: Brainstorming

---

## Goals

1. Make the codebase maintainable and understandable
2. Preserve all working features (SSD streaming, TurboQuant, prompt cache, Wisdom calibration)
3. Keep both macOS CLI and iOS app targets
4. Set up a clean foundation for future features (MCP server integration on iOS)
5. Keep OpenAI-compatible API endpoints stable

## Non-Goals

- Upstream PR compatibility (we own this fork)
- Adding new features during the refactoring pass
- Rewriting the ML/inference layer itself (MLX Swift dependencies stay as-is)

---

## Current Pain Points

### 1. Monolithic Server.swift (2,279 lines)
Single file contains: CLI arg parsing, HTTP server setup, routing, middleware, request handlers,
streaming SSE formatting, prompt caching, thinking-tag parsing, JSON serialization, concurrency
primitives, stop sequence detection, and all OpenAI-compatible type definitions.

### 2. Unsafe JSON patterns
- 11 instances of `JSONSerialization` with `try!` (crash risk in production)
- Hand-built `[String: Any]` dictionaries instead of `Codable` structs
- String-interpolated JSON in the `/health` endpoint (no escaping)

### 3. Duplicated tokenizer bridges
`Server.swift` and `InferenceEngine.swift` both define identical `HubDownloader`,
`TransformersTokenizerLoader`, and `TransformersTokenizerBridge` (~70 lines copy-pasted).

### 4. No structured logging
64 `print()` calls with no levels, timestamps, or ability to disable.

### 5. Global state mutations
`Memory.cacheLimit` and `Memory.memoryLimit` set as globals during request handling.

### 6. Opaque calibration system
Wisdom/Calibrator has magic numbers, no documentation, and unclear trial selection heuristics.

---

## Systems to Preserve

| System | Purpose | Notes |
|--------|---------|-------|
| SSD Expert Streaming | Memory-maps expert weights from SSD for huge MoE models | The killer feature. Keep and clean up. |
| TurboQuant KV | 3-bit KV cache compression for 100k+ context | Keep behind flag. Complex but working. |
| Prompt Cache | Saves/restores KV state for repeated conversation prefixes | Useful for interactive use. Extract to own module. |
| Wisdom Calibration | Auto-tunes memory limits per model/hardware | Keep but document the algorithm and magic numbers. |
| Layer Partitioning | Splits model layers between GPU and CPU | Part of ModelProfiler. Already reasonably clean. |

---

## Ideas / Future Features

- [ ] MCP server integration on iOS (SwiftBuddy as MCP server/client for on-device inference)
- [ ] Strip dead CLI flags (identify which ones actually wire through to behavior)
- [ ] Structured logging with os.Logger
- [ ] Proper error responses instead of crashes on malformed input

---

## Design Decisions (TBD)

- Approach for splitting Server.swift (see Approaches section below)
- Whether to merge MLXInferenceCore back or keep as separate target
- CLI flag audit: which flags are dead?
- Testing strategy (if any)

---

## Approaches

*To be filled in after brainstorming is complete.*
