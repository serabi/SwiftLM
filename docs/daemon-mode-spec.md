# Feature Spec: Ollama-Style Daemon Mode for SwiftLM

## Context

SwiftLM currently runs as a foreground terminal process that loads a single model at startup and holds it in memory until the process exits. There's no way to:
- Run it as a background service
- Load/unload models on demand
- Switch models without restarting
- Automatically free memory when idle

Ollama solves this with a daemon that starts instantly, loads models on first request, and unloads them after an idle timeout. This spec adds equivalent functionality to SwiftLM.

The iOS app (`InferenceEngine.swift`) already implements background offload, memory pressure handling, and model switching -- we'll adapt those patterns for the server.

---

## Architecture Overview

### New: `ModelManager` actor

Central coordinator replacing direct `ModelContainer` usage. All handlers go through this instead of holding a fixed container reference.

```
Request --> Handler --> ModelManager.ensureLoaded() --> ModelContainer
                              |
                       (loads if idle)
                              |
                 IdleMonitor --+--> unload after timeout
```

### Key files to create

| File | Purpose |
|---|---|
| `Sources/SwiftLM/ModelManager.swift` | New actor: lifecycle, load/unload, idle tracking |
| `Sources/SwiftLM/Handlers/ModelHandler.swift` | New: `/v1/models` endpoints |

### Key files to modify

| File | Change |
|---|---|
| `Sources/SwiftLM/SwiftLM.swift` | Add `--daemon`, `--idle-timeout`, `--preload` flags |
| `Sources/SwiftLM/ServerBootstrap.swift` | Decouple server start from model load; create ModelManager |
| `Sources/SwiftLM/Routes.swift` | Pass `ModelManager` instead of `ModelContainer`; add model endpoints |
| `Sources/SwiftLM/Handlers/ChatHandler.swift` | Call `modelManager.ensureLoaded()` instead of using fixed container |
| `Sources/SwiftLM/Handlers/TextHandler.swift` | Same as ChatHandler |
| `Sources/SwiftLM/Handlers/HealthHandler.swift` | Report model state (idle/loading/ready/generating) |
| `Sources/SwiftLM/Models/ServerConfig.swift` | Add `lastRequestAt` to ServerStats |

---

## Implementation Plan

### Phase 1: ModelManager actor

Create `Sources/SwiftLM/ModelManager.swift`:

```swift
actor ModelManager {
    enum State: Sendable {
        case idle
        case loading(modelId: String)
        case ready(modelId: String)
        case error(String)
    }

    private(set) var state: State = .idle
    private var container: ModelContainer?
    private var lastRequestAt: Date?
    private var idleTimeoutSeconds: TimeInterval
    private var idleTask: Task<Void, Never>?

    // Configuration captured at server start for reuse during reload
    private let serverOptions: MLXServer

    init(options: MLXServer, idleTimeout: TimeInterval = 300)

    /// Returns a loaded container, loading the model first if needed.
    /// Called by every handler before processing a request.
    func ensureLoaded() async throws -> ModelContainer

    /// Load a specific model (for model switching via API).
    func load(modelId: String) async throws

    /// Unload the current model and free memory.
    func unload()

    /// Snapshot for health/stats endpoints.
    func snapshot() -> ModelSnapshot

    /// Called after every request to reset the idle timer.
    private func touchAndResetIdleTimer()

    /// Background task that fires after idleTimeoutSeconds of inactivity.
    private func scheduleIdleUnload()
}
```

**Key behaviors:**

- `ensureLoaded()` checks `state`: if `.ready`, updates `lastRequestAt` and returns container. If `.idle`, triggers `load()` and waits. If `.loading`, waits for load to complete (using AsyncStream or continuation). If `.error`, throws.
- `touchAndResetIdleTimer()` cancels any pending `idleTask`, then spawns a new `Task.sleep(for:)` that calls `unload()` when it fires.
- `unload()` sets `container = nil`, calls `ExpertStreamingConfig.shared.deactivate()`, resets `MLX.Memory.cacheLimit = 0`, sets state to `.idle`. Pattern adapted from `InferenceEngine.unload()` (line 287-294 of InferenceEngine.swift).
- `load()` reuses the existing model loading logic from `ServerBootstrap.start()` lines 131-205 (factory load, GPU layers, SSD streaming, wisdom calibration). This logic should be extracted into a shared function both ServerBootstrap and ModelManager can call.

### Phase 2: Refactor ServerBootstrap

Modify `Sources/SwiftLM/ServerBootstrap.swift`:

**Before (current):**
```
start() -> load model -> create container -> build router(container) -> run server
```

**After:**
```
start() -> create ModelManager -> optionally preload model -> build router(modelManager) -> run server
```

Changes:

1. Extract model loading logic (lines 131-205) into a standalone function:
   ```swift
   static func loadModel(options: MLXServer, modelId: String) async throws -> (ModelContainer, PartitionPlan?)
   ```
   This function handles: factory selection (LLM vs VLM), GPU layer config, SSD streaming activation, wisdom calibration.

2. Create `ModelManager` with server options.

3. If `--preload` flag is set (or `--daemon` is not set), call `modelManager.load()` at startup (preserving current behavior as default).

4. If `--daemon` is set without `--preload`, skip initial load -- the model loads on first request.

5. Pass `ModelManager` (not `ModelContainer`) to `buildRouter()`.

### Phase 3: Update handlers

Modify `ChatHandler.swift`, `TextHandler.swift`:

**Before:**
```swift
func handleChatCompletion(
    ...
    container: ModelContainer,
    ...
) async throws -> Response
```

**After:**
```swift
func handleChatCompletion(
    ...
    modelManager: ModelManager,
    ...
) async throws -> Response {
    let container = try await modelManager.ensureLoaded()
    // ... rest unchanged
}
```

This is a mechanical change -- every handler that currently takes `container: ModelContainer` takes `modelManager: ModelManager` instead, and calls `ensureLoaded()` at the top.

The semaphore stays as-is -- it limits concurrent generation, not model loading. Model loading has its own serialization via the actor.

### Phase 4: Update Routes

Modify `Sources/SwiftLM/Routes.swift`:

1. Change `buildRouter` signature: replace `container: ModelContainer` with `modelManager: ModelManager`.
2. Pass `modelManager` to handler calls instead of `container`.
3. Add new endpoints:

```swift
// List models (Ollama/OpenAI compatible)
router.get("/v1/models") { ... }

// Load a model by ID
router.post("/v1/models/load") { ... }

// Unload current model
router.post("/v1/models/unload") { ... }
```

### Phase 5: Model management endpoints

Create `Sources/SwiftLM/Handlers/ModelHandler.swift`:

**`POST /v1/models/load`**
```json
// Request
{ "model": "mlx-community/Qwen3.5-27B-4bit" }

// Response
{ "status": "loaded", "model": "mlx-community/Qwen3.5-27B-4bit" }
```
Calls `modelManager.load(modelId:)`. If a different model is loaded, unloads it first.

**`POST /v1/models/unload`**
```json
// Response
{ "status": "unloaded" }
```
Calls `modelManager.unload()`.

**`GET /v1/models`**
Returns currently loaded model and state. Compatible with OpenAI's model list format:
```json
{
  "object": "list",
  "data": [{
    "id": "mlx-community/Qwen3.5-27B-4bit",
    "object": "model",
    "state": "ready"
  }]
}
```

### Phase 6: Health endpoint updates

Modify `Sources/SwiftLM/Handlers/HealthHandler.swift`:

Add `model_state` field to `HealthResponse`:
```swift
struct HealthResponse: Encodable {
    let status: String          // "ok" even when model unloaded (server is healthy)
    let model: String?          // nil when no model loaded
    let modelState: String      // "idle", "loading", "ready", "error"
    let vision: Bool
    let memory: MemoryInfo
    let stats: StatsInfo
    let partition: PartitionInfo?
}
```

When model is unloaded, `/health` still returns 200 (the server is healthy), but `model` is null and `modelState` is "idle".

### Phase 7: ServerStats idle tracking

Modify `Sources/SwiftLM/Models/ServerConfig.swift`:

Add to `ServerStats`:
```swift
private var lastRequestAt: Date?

func requestStarted() {
    requestsTotal += 1
    requestsActive += 1
    lastRequestAt = Date()
}
```

Add to `Snapshot`:
```swift
let lastRequestAt: Date?
let idleDurationSeconds: TimeInterval?  // Computed: now - lastRequestAt
```

### Phase 8: CLI flags

Modify `Sources/SwiftLM/SwiftLM.swift`:

```swift
@Flag(name: .long, help: "Run as background daemon (defer model loading until first request)")
var daemon: Bool = false

@Option(name: .long, help: "Seconds of inactivity before unloading model (0 = never, default: 300)")
var idleTimeout: Int = 300

@Flag(name: .long, help: "Pre-load model at startup even in daemon mode")
var preload: Bool = false
```

Behavior matrix:

| Flags | Startup | Idle behavior |
|---|---|---|
| (none, current default) | Load model immediately | Never unload (backward compat) |
| `--daemon` | Start server, defer load | Unload after idle timeout |
| `--daemon --preload` | Load model immediately | Unload after idle timeout |
| `--idle-timeout 0` | Load model immediately | Never unload |
| `--daemon --idle-timeout 600` | Defer load | Unload after 10 min idle |

### Phase 9 (optional): LaunchAgent template

Ship a `resources/com.swiftlm.server.plist` template that users can install to `~/Library/LaunchAgents/`. Starts SwiftLM in daemon mode on login, restarts on crash.

---

## What stays the same

- Prompt cache behavior (per-request, managed by PromptCache)
- SSD streaming, TurboQuant, GPU layer partitioning (all configured during load)
- Semaphore-based concurrency limiting
- All existing CLI flags and their behavior when `--daemon` is not used
- Wisdom calibration (runs during model load, cached for next time)

## Backward compatibility

Without `--daemon`, SwiftLM behaves exactly as it does today: load model at startup, hold forever, no idle unload. The ModelManager wraps the same container but with `idleTimeout = 0` (never unload).

---

## Verification

1. **Basic daemon mode**: Start with `--daemon --model <id>`, confirm server responds to `/health` immediately with `modelState: "idle"`. Send a chat request, confirm model loads and responds. Check `/health` shows `modelState: "ready"`.

2. **Idle unload**: Start with `--daemon --idle-timeout 10 --model <id>`. Send a request. Wait 15 seconds. Check `/health` shows `modelState: "idle"`. Send another request, confirm it loads and responds.

3. **Model switching**: Start with `--daemon`. POST to `/v1/models/load` with model A. Send a request. POST to `/v1/models/load` with model B. Send a request. Confirm responses are from different models.

4. **Backward compat**: Start without `--daemon`. Confirm model loads at startup and never unloads. All existing tests pass.

5. **Memory reclaim**: Monitor GPU memory via `ioreg` (same as profiler). After idle unload, confirm GPU allocated memory drops back to baseline.
