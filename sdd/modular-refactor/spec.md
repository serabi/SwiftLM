# Spec: SwiftLM Modular Refactor

## Goal

Decompose the monolithic SwiftLM codebase (primarily the 2,279-line Server.swift) into focused,
single-responsibility modules. Replace unsafe JSON patterns with type-safe Codable structs, add
structured logging, deduplicate shared code, and document opaque subsystems. The refactoring
preserves all existing behavior while making the codebase maintainable and extensible for future
features like MCP server integration.

## Requirements Summary

- Split Server.swift into focused modules (~6-8 new files)
- Deduplicate tokenizer bridges between Server.swift and InferenceEngine.swift
- Replace `try!` / `[String: Any]` JSON with Codable structs throughout
- Replace 64 `print()` calls with structured `os.Logger` logging
- Extract prompt cache, thinking parser, SSE formatting, middleware into own files
- Document Calibrator algorithm and magic numbers
- Audit CLI flags for dead options
- Keep OpenAI API compatibility, both targets building, all inference features working

## Chosen Approach

**Modular Restructure (Approach B)**

Systematic decomposition of Server.swift into discrete modules organized by responsibility,
combined with type safety improvements and logging infrastructure. Each extraction preserves
the existing logic verbatim (move first, improve second) to minimize behavioral risk.

Selected over Approach A (too conservative — leaves logging, global state, and bootstrap mess
untouched) and Approach C (too risky — rewriting the server layer could lose hard-won inference
bug fixes documented in journal.md).

### Alternatives Considered

**Approach A (Surgical Split):** Only splits Server.swift and deduplicates bridges. Faster but
leaves 64 print() calls, no structured bootstrap, and undocumented calibrator. Would still need
a second pass for anything beyond basic maintenance.

**Approach C (Clean-Room Core):** Rewrite the server from scratch using existing code as reference.
Cleanest result but highest risk — the prompt cache has subtle correctness requirements (lazy
MLXArray eval timing, TurboQuant snapshot avoidance, sliding-window KV length checks) that are
easy to lose in a rewrite.

## Technical Details

### Architecture

The refactoring reorganizes Sources/SwiftLM/ from 4 files into a module structure with clear
dependency flow:

```
SwiftLM.swift (CLI entry point)
    |
    v
ServerBootstrap (model load, memory config, calibration)
    |
    v
Routes (Hummingbird router, middleware registration)
    |
    +---> ChatHandler     --+
    +---> TextHandler      -+--> SSEFormatter (Codable chunk builders)
    +---> HealthHandler    |     ThinkingStateTracker
    +---> MetricsHandler   |
                            v
                    PromptCache, ServerConfig, ServerStats
                    AsyncSemaphore, Log, MemoryUtils
```

MLXInferenceCore gains one new file (TokenizerBridges.swift) and loses duplicate code
from InferenceEngine.swift.

### Key Components

Each component below maps to a new file. The "Source lines" column shows which lines of
the current Server.swift move into each file.

**Sources/SwiftLM/SwiftLM.swift** (new, ~60 lines)
- `@main struct MLXServer: AsyncParsableCommand` with all `@Option`/`@Flag` declarations
- `run()` delegates immediately to `ServerBootstrap.start(options:)`
- Keeps argument parsing separate from all server logic

**Sources/SwiftLM/ServerBootstrap.swift** (new, ~300 lines)
- Model loading (local path vs HuggingFace, VLM vs LLM)
- SSD Expert Streaming activation
- Memory strategy selection (fullGPU / swapAssisted / layerPartitioned / tooLarge)
- GPU layer partitioning
- Wisdom calibration (load or run)
- ServerConfig construction
- Signal handlers (SIGTERM/SIGINT)
- Hummingbird Application creation and `runService()`
- Source: Server.swift lines 252-724

**Sources/SwiftLM/Routes.swift** (new, ~80 lines)
- `func buildRouter(...)` that registers all endpoints
- CORS and API key middleware attachment
- Route closures that delegate to handler functions
- Error response wrapping (the catch blocks that build error JSON)
- Source: Server.swift lines 502-607, 668-672

**Sources/SwiftLM/Handlers/ChatHandler.swift** (new, ~400 lines)
- `handleChatCompletion()` — request parsing, message conversion, cache-aware generation setup
- `handleChatStreaming()` — SSE streaming with prefill heartbeat, thinking routing, tool calls
- `handleChatNonStreaming()` — buffered response with thinking extraction
- `extractThinkingBlock()` helper
- PrefillState actor
- Source: Server.swift lines 929-1571

**Sources/SwiftLM/Handlers/TextHandler.swift** (new, ~200 lines)
- `handleTextCompletion()` — request parsing, generation
- `handleTextStreaming()` — SSE streaming with stop sequence detection
- `handleTextNonStreaming()` — buffered response
- Source: Server.swift lines 1573-1750

**Sources/SwiftLM/Handlers/HealthHandler.swift** (new, ~60 lines)
- `/health` endpoint logic, converted from string interpolation to Codable struct
- Source: Server.swift lines 516-554

**Sources/SwiftLM/Handlers/MetricsHandler.swift** (new, ~80 lines)
- `/metrics` Prometheus endpoint
- `/v1/models` model list endpoint
- Source: Server.swift lines 557-666

**Sources/SwiftLM/Streaming/SSEFormatter.swift** (new, ~150 lines)
- Codable structs: `SSEChatChunk`, `SSEPrefillChunk`, `SSEUsageChunk`, `SSEToolCallChunk`, `SSETextChunk`
- Builder functions: `sseChunk()`, `ssePrefillChunk()`, `sseUsageChunk()`, `sseToolCallChunk()`, `sseTextChunk()`
- All `try!` replaced with `do/catch` that falls back to a minimal error SSE event
- `sseHeaders()` and `jsonHeaders()` helpers
- Source: Server.swift lines 1863-1997

**Sources/SwiftLM/Streaming/ThinkingStateTracker.swift** (new, ~60 lines)
- `ThinkingStateTracker` struct — moved verbatim
- Source: Server.swift lines 1142-1201

**Sources/SwiftLM/Caching/PromptCache.swift** (new, ~80 lines)
- `PromptCache` actor — moved verbatim
- Source: Server.swift lines 839-917

**Sources/SwiftLM/Caching/Calibrator.swift** (existing, modified)
- Add doc comments explaining the Wisdom algorithm
- Document magic numbers (trial cache limits, maxTokens=30, etc.)
- No behavioral changes

**Sources/SwiftLM/Models/APITypes.swift** (new, ~250 lines)
- All OpenAI-compatible request types: `ChatCompletionRequest`, `TextCompletionRequest`
- All response types: `ChatCompletionResponse`, `Choice`, `AssistantMessage`, `TextCompletionResponse`, `TextChoice`
- Supporting types: `StreamOptions`, `ResponseFormat`, `ToolCallResponse`, `ToolCallFunction`, `TokenUsage`
- Source: Server.swift lines 2007-2279

**Sources/SwiftLM/Models/ServerConfig.swift** (new, ~60 lines)
- `ServerConfig` struct
- `ServerStats` actor
- Source: Server.swift lines 727-835

**Sources/SwiftLM/Models/AnyCodable.swift** (new, ~40 lines)
- `AnyCodable` struct and Decodable extension
- `serializeToolCallArgs()` helper
- Source: Server.swift lines 2238-2267, 1999-2005

**Sources/SwiftLM/Utilities/Log.swift** (new, ~40 lines)
- `enum Log` with static methods: `info()`, `debug()`, `warning()`, `error()`
- Uses `swift-log` (`Logging` package) — already a transitive dependency via Hummingbird
- Consistent with the HTTP framework's own logging
- Replaces all 64 `print()` calls throughout the codebase
- Default `StreamLogHandler` outputs to stdout, matching current `print()` behavior

**Sources/SwiftLM/Utilities/AsyncSemaphore.swift** (new, ~30 lines)
- `AsyncSemaphore` actor — moved verbatim
- Source: Server.swift lines 1752-1782

**Sources/SwiftLM/Middleware/CORSMiddleware.swift** (new, ~40 lines)
- `CORSMiddleware` struct — moved verbatim
- Source: Server.swift lines 1784-1819

**Sources/SwiftLM/Middleware/ApiKeyMiddleware.swift** (new, ~30 lines)
- `ApiKeyMiddleware` struct — moved verbatim
- Source: Server.swift lines 1821-1849

**Sources/SwiftLM/Utilities/ModelDirectoryResolver.swift** (new, ~50 lines)
- `resolveModelDirectory()` function — moved verbatim
- Source: Server.swift lines 748-795

**Sources/SwiftLM/Utilities/ProgressTracker.swift** (new, ~110 lines)
- `ProgressTracker` class — moved verbatim
- Source: Server.swift lines 75-183

**Sources/MLXInferenceCore/TokenizerBridges.swift** (new, ~50 lines)
- Shared `HubDownloader`, `TransformersTokenizerLoader`, `TransformersTokenizerBridge`
- Made `internal` (not private) so both SwiftLM and InferenceEngine can use them
- Note: SwiftLM target doesn't depend on MLXInferenceCore currently. The bridges
  will be duplicated but extracted to their own file in each target for now. A future
  refactoring could make SwiftLM depend on MLXInferenceCore to truly share the code,
  but that changes the dependency graph and is out of scope.

**Sources/MLXInferenceCore/InferenceEngine.swift** (modified)
- Remove lines 15-66 (duplicate bridge structs)
- Import from TokenizerBridges.swift instead

### File Changes Summary

| File | Change | Description |
|------|--------|-------------|
| Sources/SwiftLM/Server.swift | delete | Replaced entirely by new modules |
| Sources/SwiftLM/SwiftLM.swift | new | CLI entry point with argument parsing |
| Sources/SwiftLM/ServerBootstrap.swift | new | Model loading, memory config, server startup |
| Sources/SwiftLM/Routes.swift | new | Router setup and endpoint registration |
| Sources/SwiftLM/Handlers/ChatHandler.swift | new | Chat completions (streaming + non-streaming) |
| Sources/SwiftLM/Handlers/TextHandler.swift | new | Text completions (streaming + non-streaming) |
| Sources/SwiftLM/Handlers/HealthHandler.swift | new | /health endpoint with Codable response |
| Sources/SwiftLM/Handlers/MetricsHandler.swift | new | /metrics and /v1/models endpoints |
| Sources/SwiftLM/Streaming/SSEFormatter.swift | new | Codable SSE chunk builders |
| Sources/SwiftLM/Streaming/ThinkingStateTracker.swift | new | Think-tag parser |
| Sources/SwiftLM/Caching/PromptCache.swift | new | KV cache save/restore actor |
| Sources/SwiftLM/Caching/Calibrator.swift | modify | Add documentation (no behavioral changes) |
| Sources/SwiftLM/Models/APITypes.swift | new | OpenAI-compatible request/response types |
| Sources/SwiftLM/Models/ServerConfig.swift | new | ServerConfig + ServerStats |
| Sources/SwiftLM/Models/AnyCodable.swift | new | Type-erased JSON wrapper |
| Sources/SwiftLM/Utilities/Log.swift | new | Structured logging via os.Logger |
| Sources/SwiftLM/Utilities/AsyncSemaphore.swift | new | Concurrency limiter actor |
| Sources/SwiftLM/Utilities/ModelDirectoryResolver.swift | new | HuggingFace cache path resolution |
| Sources/SwiftLM/Utilities/ProgressTracker.swift | new | Download progress display |
| Sources/SwiftLM/Middleware/CORSMiddleware.swift | new | CORS middleware |
| Sources/SwiftLM/Middleware/ApiKeyMiddleware.swift | new | API key auth middleware |
| Sources/MLXInferenceCore/TokenizerBridges.swift | new | Shared tokenizer bridge structs |
| Sources/MLXInferenceCore/InferenceEngine.swift | modify | Remove duplicate bridges |
| Sources/SwiftLM/MemoryUtils.swift | no change | Already clean |
| Sources/SwiftLM/ModelProfiler.swift | no change | Already clean |

## Out of Scope

- MCP server/client integration (future feature, builds on this clean foundation)
- Adding unit tests (would be valuable but is a separate effort)
- Rewriting the MLX inference pipeline or touching dependency forks
- Changes to the iOS SwiftBuddy app (beyond the tokenizer bridge dedup in MLXInferenceCore)
- Performance optimization
- New CLI flags or API endpoints

## Open Questions Resolved

**Q: Should SwiftLM depend on MLXInferenceCore to share tokenizer bridges?**
A: No. Changing the dependency graph is a separate concern. For now, extract bridges to their
own file in each target. The duplication is contained (one file each) and clearly marked.

**Q: Should we use `os.Logger` or `swift-log` (the `Logging` package)?**
A: `swift-log`. Hummingbird already depends on it, so it's in the dependency tree. Using the
same logging framework as the HTTP server is more consistent. We'll add `Logging` as a direct
dependency in Package.swift and use `StreamLogHandler` for stdout output.

**Q: What about the `ProgressTracker` class that uses `print()` for download progress bars?**
A: Keep the terminal progress bar behavior as-is (it uses `\r` carriage returns for in-place
updates). The `Log` wrapper is for server operational messages, not interactive terminal UI.
ProgressTracker moves to its own file but keeps `print()`.

**Q: Are any CLI flags actually dead?**
A: To be determined during implementation. The `--parallel` flag creates an AsyncSemaphore but
the server is fundamentally single-slot due to MLX model container locking. The flag works but
its effect may be misleading. We'll document findings but won't remove flags during this pass
to avoid scope creep.
