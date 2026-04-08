# Implementation Plan: SwiftLM Modular Refactor

Based on: sdd/modular-refactor/spec.md

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

## Strategy

Extract leaf dependencies first (types, utilities), then consumers (handlers, streaming),
then wiring (routes, bootstrap), then delete the old file. The project should compile after
every task. Each extraction is "move first, improve second" to minimize behavioral risk.

**Important:** Server.swift remains the working file throughout. Each task extracts code INTO
a new file but does NOT remove it from Server.swift yet. Task 21 deletes Server.swift after
all extractions are complete and verified. This means there will be temporary duplicate
symbols — use `internal` access and disambiguate with module prefixes if needed, or remove
from Server.swift as you extract (preferred if you can verify the build after each step).

## Tasks

### Task 1: Create directory structure
- **Files**: Sources/SwiftLM/ subdirectories
- **Do**:
  1. Create directories: `Handlers/`, `Streaming/`, `Caching/`, `Models/`, `Utilities/`, `Middleware/`
  2. Verify directory structure exists
- **Verify**: `ls -R Sources/SwiftLM/` shows all subdirectories
- **Depends on**: none
- **Commit**: `chore(swiftlm): create module directory structure`

### Task 2: Extract APITypes.swift
- **Files**: `Sources/SwiftLM/Models/APITypes.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Models/APITypes.swift`
  2. Move from Server.swift: `StreamOptions`, `ResponseFormat`, `ChatCompletionRequest` (and all nested types: `Message`, `MessageContent`, `ContentPart`, `ImageUrlContent`, `ToolDef`, `ToolFuncDef`), `TextCompletionRequest`, `ChatCompletionResponse`, `Choice`, `AssistantMessage`, `ToolCallResponse`, `ToolCallFunction`, `TextCompletionResponse`, `TextChoice`, `TokenUsage` (lines 2007-2279)
  3. Also move `AnyCodable` struct and extension, and `serializeToolCallArgs()` (lines 1999-2005, 2238-2267)
  4. Remove moved code from Server.swift
  5. Add necessary imports (`Foundation`, `CoreImage`, `MLXLMCommon`)
  6. Verify build: `swift build`
- **Verify**: `swift build` succeeds, all types accessible from other Server.swift code
- **Depends on**: Task 1
- **Commit**: `refactor(swiftlm): extract API types to Models/APITypes.swift`

### Task 3: Extract ServerConfig.swift
- **Files**: `Sources/SwiftLM/Models/ServerConfig.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Models/ServerConfig.swift`
  2. Move `ServerConfig` struct (lines 727-741) and `ServerStats` actor (lines 797-835)
  3. Remove moved code from Server.swift
  4. Add necessary imports (`Foundation`)
  5. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Task 1
- **Commit**: `refactor(swiftlm): extract ServerConfig and ServerStats to Models/ServerConfig.swift`

### Task 4: Extract AsyncSemaphore.swift
- **Files**: `Sources/SwiftLM/Utilities/AsyncSemaphore.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Utilities/AsyncSemaphore.swift`
  2. Move `AsyncSemaphore` actor (lines 1752-1782)
  3. Remove moved code from Server.swift
  4. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Task 1
- **Commit**: `refactor(swiftlm): extract AsyncSemaphore to Utilities/AsyncSemaphore.swift`

### Task 5: Create Log.swift
- **Files**: `Sources/SwiftLM/Utilities/Log.swift`, `Package.swift`
- **Do**:
  1. Add `.product(name: "Logging", package: "swift-log")` to SwiftLM target dependencies in Package.swift
  2. Add `.package(url: "https://github.com/apple/swift-log", from: "1.5.0")` to package dependencies (check if already present via Hummingbird transitive dep — if so, just add the product to target)
  3. Create `Utilities/Log.swift` with:
     - `import Logging`
     - `enum Log` with static `logger` property (label: "com.swiftlm.server")
     - Static methods: `info(_ message: String)`, `debug(_ message: String)`, `warning(_ message: String)`, `error(_ message: String)`
     - Bootstrap `LoggingSystem` with `StreamLogHandler.standardOutput` in a static initializer
  4. Verify build: `swift build`
- **Verify**: `swift build` succeeds, `Log.info("test")` compiles
- **Depends on**: Task 1
- **Commit**: `feat(swiftlm): add structured logging via swift-log`

### Task 6: Extract ProgressTracker.swift
- **Files**: `Sources/SwiftLM/Utilities/ProgressTracker.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Utilities/ProgressTracker.swift`
  2. Move `ProgressTracker` class (lines 75-183)
  3. Remove moved code from Server.swift
  4. Add necessary imports (`Foundation`)
  5. Keep `print()` calls as-is (terminal progress bar, not operational logging)
  6. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Task 1
- **Commit**: `refactor(swiftlm): extract ProgressTracker to Utilities/ProgressTracker.swift`

### Task 7: Extract ModelDirectoryResolver.swift
- **Files**: `Sources/SwiftLM/Utilities/ModelDirectoryResolver.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Utilities/ModelDirectoryResolver.swift`
  2. Move `resolveModelDirectory()` function (lines 748-795)
  3. Remove moved code from Server.swift
  4. Add necessary imports (`Foundation`)
  5. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Task 1
- **Commit**: `refactor(swiftlm): extract resolveModelDirectory to Utilities/ModelDirectoryResolver.swift`

### Task 8: Extract middleware files
- **Files**: `Sources/SwiftLM/Middleware/CORSMiddleware.swift`, `Sources/SwiftLM/Middleware/ApiKeyMiddleware.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Middleware/CORSMiddleware.swift` — move `CORSMiddleware` struct (lines 1784-1819)
  2. Create `Middleware/ApiKeyMiddleware.swift` — move `ApiKeyMiddleware` struct (lines 1821-1849)
  3. Remove moved code from Server.swift
  4. Add necessary imports (`Foundation`, `HTTPTypes`, `Hummingbird`)
  5. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Task 1
- **Commit**: `refactor(swiftlm): extract CORS and API key middleware`

### Task 9: Extract TokenizerBridges.swift
- **Files**: `Sources/SwiftLM/Utilities/TokenizerBridges.swift`, `Sources/MLXInferenceCore/TokenizerBridges.swift`, `Sources/MLXInferenceCore/InferenceEngine.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Sources/SwiftLM/Utilities/TokenizerBridges.swift` with `HubDownloader`, `TransformersTokenizerLoader`, `TransformersTokenizerBridge` from Server.swift lines 26-71
  2. Change access from `private` to `internal`
  3. Remove bridge structs from Server.swift (lines 26-71)
  4. Create `Sources/MLXInferenceCore/TokenizerBridges.swift` with same structs from InferenceEngine.swift lines 15-66
  5. Change access from `private` to `internal`
  6. Remove bridge structs from InferenceEngine.swift (lines 15-66)
  7. Verify build: `swift build`
- **Verify**: `swift build` succeeds, both targets compile
- **Depends on**: Task 1
- **Commit**: `refactor: extract tokenizer bridges to dedicated files in both targets`

### Task 10: Extract PromptCache.swift
- **Files**: `Sources/SwiftLM/Caching/PromptCache.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Caching/PromptCache.swift`
  2. Move `PromptCache` actor and its `CachedState` struct (lines 839-917)
  3. Remove moved code from Server.swift
  4. Add necessary imports (`Foundation`, `MLX`, `MLXLMCommon`)
  5. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Task 1
- **Commit**: `refactor(swiftlm): extract PromptCache to Caching/PromptCache.swift`

### Task 11: Extract ThinkingStateTracker.swift
- **Files**: `Sources/SwiftLM/Streaming/ThinkingStateTracker.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Streaming/ThinkingStateTracker.swift`
  2. Move `ThinkingStateTracker` struct (lines 1142-1201)
  3. Move `extractThinkingBlock()` function (lines 1556-1571)
  4. Remove moved code from Server.swift
  5. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Task 1
- **Commit**: `refactor(swiftlm): extract ThinkingStateTracker to Streaming/ThinkingStateTracker.swift`

### Task 12: Create SSEFormatter.swift with Codable structs
- **Files**: `Sources/SwiftLM/Streaming/SSEFormatter.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Streaming/SSEFormatter.swift`
  2. Define Codable structs for each SSE chunk type:
     - `SSEChatChunk` (replaces hand-built dict in `sseChunk()`)
     - `SSEPrefillChunk` (replaces dict in `ssePrefillChunk()`)
     - `SSEUsageChunk` (replaces dict in `sseUsageChunk()`)
     - `SSEToolCallChunk` (replaces dict in `sseToolCallChunk()`)
     - `SSETextChunk` (replaces dict in `sseTextChunk()`)
  3. Rewrite builder functions to create Codable structs and use `JSONEncoder` instead of `JSONSerialization` + `try!`
  4. Use `do/catch` with fallback to minimal error event instead of force-unwrap
  5. Move `sseHeaders()`, `jsonHeaders()`, `checkStopSequences()`, `collectBody()` helpers
  6. Remove moved code from Server.swift
  7. Verify build: `swift build`
  8. Verify JSON output matches original format (same keys, same structure) by inspection
- **Verify**: `swift build` succeeds, SSE functions produce identical JSON structure
- **Depends on**: Task 2
- **Commit**: `refactor(swiftlm): replace unsafe JSON serialization with Codable SSE types`

### Task 13: Extract ChatHandler.swift
- **Files**: `Sources/SwiftLM/Handlers/ChatHandler.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Handlers/ChatHandler.swift`
  2. Move `handleChatCompletion()` (lines 929-1134)
  3. Move `PrefillState` actor (lines 1208-1213)
  4. Move `handleChatStreaming()` (lines 1215-1423)
  5. Move `handleChatNonStreaming()` (lines 1427-1553)
  6. Remove moved code from Server.swift
  7. Add necessary imports (`Foundation`, `MLX`, `MLXLLM`, `MLXLMCommon`, `MLXVLM`, `Hummingbird`, `HTTPTypes`, `Tokenizers`)
  8. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Tasks 2, 3, 4, 10, 11, 12
- **Commit**: `refactor(swiftlm): extract chat completion handlers`

### Task 14: Extract TextHandler.swift
- **Files**: `Sources/SwiftLM/Handlers/TextHandler.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Handlers/TextHandler.swift`
  2. Move `handleTextCompletion()` (lines 1573-1628)
  3. Move `handleTextStreaming()` (lines 1632-1695)
  4. Move `handleTextNonStreaming()` (lines 1699-1750)
  5. Remove moved code from Server.swift
  6. Add necessary imports
  7. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Tasks 2, 3, 4, 12
- **Commit**: `refactor(swiftlm): extract text completion handlers`

### Task 15: Extract HealthHandler.swift
- **Files**: `Sources/SwiftLM/Handlers/HealthHandler.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Handlers/HealthHandler.swift`
  2. Move `/health` endpoint logic (lines 516-554)
  3. Replace string-interpolated JSON with a Codable `HealthResponse` struct
  4. Remove moved code from Server.swift
  5. Verify build: `swift build`
  6. Verify JSON output matches original structure
- **Verify**: `swift build` succeeds, `/health` response has same fields
- **Depends on**: Task 3
- **Commit**: `refactor(swiftlm): extract health endpoint with Codable response`

### Task 16: Extract MetricsHandler.swift
- **Files**: `Sources/SwiftLM/Handlers/MetricsHandler.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Handlers/MetricsHandler.swift`
  2. Move `/metrics` Prometheus endpoint logic (lines 609-666)
  3. Move `/v1/models` endpoint logic (lines 557-566)
  4. Remove moved code from Server.swift
  5. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Task 3
- **Commit**: `refactor(swiftlm): extract metrics and models endpoints`

### Task 17: Create Routes.swift
- **Files**: `Sources/SwiftLM/Routes.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `Routes.swift`
  2. Create `func buildRouter(config:container:semaphore:stats:promptCache:partitionPlan:isSSDStream:corsOrigin:apiKey:) -> Router<BasicRequestContext>` (or appropriate Hummingbird generic)
  3. Move route registration from Server.swift `run()` (lines 502-607, 668-672)
  4. Delegate to handler functions from Tasks 13-16
  5. Keep error-wrapping catch blocks in route closures
  6. Remove moved code from Server.swift
  7. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Tasks 8, 13, 14, 15, 16
- **Commit**: `refactor(swiftlm): extract route registration to Routes.swift`

### Task 18: Create ServerBootstrap.swift
- **Files**: `Sources/SwiftLM/ServerBootstrap.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `ServerBootstrap.swift`
  2. Create `struct ServerBootstrap` with `static func start(options: MLXServer) async throws`
  3. Move from Server.swift `run()`: model loading, SSD streaming activation, memory strategy, GPU layer partitioning, calibration, config construction, memory limit override, server creation, signal handlers, ready event, `app.runService()` (lines 252-724)
  4. Call `buildRouter()` from Routes.swift
  5. Remove moved code from Server.swift (entire `run()` body)
  6. Verify build: `swift build`
- **Verify**: `swift build` succeeds
- **Depends on**: Tasks 5, 6, 7, 17
- **Commit**: `refactor(swiftlm): extract server bootstrap and startup logic`

### Task 19: Create SwiftLM.swift entry point
- **Files**: `Sources/SwiftLM/SwiftLM.swift`, `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Create `SwiftLM.swift`
  2. Move `@main struct MLXServer: AsyncParsableCommand` with all `@Option`/`@Flag` property declarations (lines 186-251)
  3. Replace `run()` body with: `try await ServerBootstrap.start(options: self)`
  4. Remove the `MLXServer` struct from Server.swift entirely
  5. Verify build: `swift build`
- **Verify**: `swift build` succeeds, `@main` entry point is in SwiftLM.swift
- **Depends on**: Task 18
- **Commit**: `refactor(swiftlm): extract CLI entry point to SwiftLM.swift`

### Task 20: Replace print() with Log across extracted files
- **Files**: All new files in `Sources/SwiftLM/` (except `Utilities/ProgressTracker.swift`)
- **Do**:
  1. Add `import Logging` to files that use `print()` for operational messages
  2. Replace `print("[SwiftLM] ...")` with `Log.info("...")`
  3. Replace `print("[SwiftLM] WARNING ...")` or `print("[SwiftLM] ⚠️ ...")` with `Log.warning("...")`
  4. Replace error-context prints with `Log.error("...")`
  5. Replace debug-level prints (token-by-token stdout, "srv  slot" lines) with `Log.debug("...")`
  6. Keep `print()` in ProgressTracker (terminal progress bars) and `fflush(stdout)` calls after real-time token streaming
  7. Initialize `LoggingSystem.bootstrap(StreamLogHandler.standardOutput)` early in ServerBootstrap
  8. Verify build: `swift build`
- **Verify**: `swift build` succeeds, no `print("[SwiftLM]` remaining except in ProgressTracker
- **Depends on**: Tasks 5, 13, 14, 15, 16, 17, 18
- **Commit**: `refactor(swiftlm): replace print() with structured swift-log logging`

### Task 21: Delete Server.swift and verify build
- **Files**: `Sources/SwiftLM/Server.swift`
- **Do**:
  1. Verify Server.swift is now empty or contains only dead code
  2. Delete Server.swift
  3. Run `swift build` to verify full compilation
  4. Verify no duplicate symbol errors
- **Verify**: `swift build` succeeds with no warnings about Server.swift
- **Depends on**: Tasks 1-20
- **Commit**: `chore(swiftlm): remove monolithic Server.swift`

### Task 22: Document Calibrator.swift
- **Files**: `Sources/SwiftLM/Calibrator.swift`
- **Do**:
  1. Read `Calibrator.swift` thoroughly
  2. Add doc comment to the file explaining the Wisdom algorithm at a high level
  3. Document each magic number: trial cache limits, `maxTokens = 30`, timing thresholds
  4. Add doc comments to public methods explaining inputs, outputs, and side effects
  5. No behavioral changes
  6. Verify build: `swift build`
- **Verify**: `swift build` succeeds, key methods have doc comments
- **Depends on**: none (independent)
- **Commit**: `docs(swiftlm): document Calibrator Wisdom algorithm and magic numbers`
