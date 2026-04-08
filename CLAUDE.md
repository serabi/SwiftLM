# SwiftLM

Native Swift inference server for Apple Silicon. Serves MLX models via OpenAI-compatible API.
Fork of SharpAI/SwiftLM with modular codebase.

## Quick Start

```bash
# Build (compiles Metal shaders + Swift binary)
./build.sh

# Run (downloads model on first use, needs HF_TOKEN for gated models)
export HF_TOKEN=hf_your_token
.build/release/SwiftLM --model mlx-community/Qwen3.5-35B-A3B-4bit --port 5413

# Test
curl http://localhost:5413/health | python3 -m json.tool
curl http://localhost:5413/stats | python3 -m json.tool
curl http://localhost:5413/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```

## Build

Always use `./build.sh`, not `swift build` directly. The build script compiles Metal GPU kernels (`mlx.metallib`) that MLX requires at runtime. Plain `swift build` will compile but crash with "Failed to load the default metallib".

Requires: macOS 14+, Apple Silicon, cmake, Metal Toolchain (build.sh installs both if missing).

## Project Structure

```
Sources/SwiftLM/
  SwiftLM.swift              # @main CLI entry point (args only)
  ServerBootstrap.swift       # Model loading, memory config, server startup
  Routes.swift                # Hummingbird router, endpoint registration
  Handlers/                   # Chat, text, health, metrics request handlers
  Streaming/                  # SSE chunk formatting (Codable), thinking tag parser
  Caching/                    # Prompt cache (KV state save/restore)
  Models/                     # OpenAI-compatible API types, server config
  Utilities/                  # Logging, async semaphore, progress tracker, tokenizer bridges
  Middleware/                 # CORS, API key auth
  Calibrator.swift            # Wisdom auto-tuning (benchmarks cache limits per model/hardware)
  ModelProfiler.swift         # Memory estimation, layer partitioning strategy
  MemoryUtils.swift           # OS-level memory measurement

Sources/MLXInferenceCore/     # Shared inference library (iOS + macOS)
SwiftBuddy/                   # iOS companion app (SwiftUI)
```

## Key Architecture

- **HTTP server**: Hummingbird (async Swift, not Vapor)
- **ML framework**: MLX Swift (Apple's Metal-accelerated ML) via SharpAI forks of mlx-swift and mlx-swift-lm
- **Logging**: swift-log to stdout + ~/.swiftlm/server.log
- **JSON**: All API responses use Codable structs (no JSONSerialization/try!)
- **Concurrency**: AsyncSemaphore actor for request slot limiting

## Key Features to Preserve

These systems have subtle correctness requirements. Be careful modifying them:

- **PromptCache** (Caching/PromptCache.swift): Saves/restores KV cache state. Has critical lazy-array materialization timing and sliding-window safety checks.
- **SSD Expert Streaming** (--stream-experts): Memory-maps MoE expert weights from SSD. Enables running models larger than RAM.
- **TurboQuant** (--turbo-kv): 3-bit KV cache compression. Has a guard that skips prompt cache save when compression is active to avoid a 37GB decompression spike.
- **Calibrator** (Calibrator.swift): Wisdom system that benchmarks cache limits. Magic numbers are documented in comments.

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat (streaming + non-streaming, tools, vision) |
| `/v1/completions` | POST | Text completions |
| `/v1/models` | GET | Model list |
| `/health` | GET | Health + memory + partition plan |
| `/stats` | GET | Token speed, request counts, memory |
| `/metrics` | GET | Prometheus format |

## CLI Flags

Common: `--model` (required), `--port`, `--host`, `--max-tokens`, `--thinking`, `--vision`
Advanced: `--stream-experts`, `--turbo-kv`, `--gpu-layers`, `--calibrate`, `--ctx-size`, `--api-key`, `--cors`
Debug: `--info` (profile memory and exit), `--prefill-size`

## Dependencies

- mlx-swift, mlx-swift-lm (SharpAI forks with GPU/CPU layer partitioning + SSD streaming)
- swift-transformers (HuggingFace tokenizers + model downloads)
- Hummingbird (HTTP server)
- swift-argument-parser (CLI)
- swift-log (logging)

## Testing

No unit tests yet. Manual testing:
1. Start server with a model
2. Hit endpoints with curl
3. Check `~/.swiftlm/server.log` and `/stats` for diagnostics
