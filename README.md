# SwiftLM

A native Swift inference server for Apple Silicon that serves [MLX](https://github.com/ml-explore/mlx) models through an **OpenAI-compatible API**.

No Python runtime, no GIL, no unnecessary memory copies. Compiles to a single binary.

<p align="center">
  <a href="https://youtu.be/E9vR5FREhMg"><img src="docs/mac_demo.gif" width="720" alt="SwiftLM Mac demo" /></a>
</p>
<p align="center">
  <img src="docs/demo.gif" width="320" alt="SwiftBuddy iOS demo" />
</p>

---

## Getting Started

### Prerequisites

- macOS 14.0+
- Apple Silicon (M1/M2/M3/M4/M5)
- Xcode Command Line Tools
- [HuggingFace account + token](https://huggingface.co/settings/tokens) (read access, for gated models)

### Build from Source

```bash
git clone --recursive https://github.com/serabi/SwiftLM
cd SwiftLM
./build.sh
```

The build script handles submodules, cmake, Metal kernel compilation (`mlx.metallib`), and the Swift release build. It will install `cmake` and the Metal Toolchain if missing.

### Run

```bash
.build/release/SwiftLM --model mlx-community/Qwen3.5-4B-MLX-4bit --port 5413
```

Models download automatically from HuggingFace on first run. Set `HF_TOKEN` for gated models:

```bash
export HF_TOKEN=hf_your_token_here
```

---

## API Endpoints

SwiftLM is a drop-in replacement for the OpenAI API. Any tool that supports custom OpenAI-compatible endpoints works out of the box.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completions (streaming + non-streaming, tool calling, vision) |
| `/v1/completions` | POST | Text completions (streaming + non-streaming) |
| `/v1/models` | GET | List loaded models |
| `/health` | GET | Server health, memory usage, partition plan |
| `/stats` | GET | Token generation speed, request counts, memory |
| `/metrics` | GET | Prometheus-compatible metrics |

### Example: Chat Completion

```bash
curl http://localhost:5413/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "max_tokens": 200
  }'
```

### Example: Streaming

```bash
curl http://localhost:5413/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Count to 10"}],
    "stream": true,
    "max_tokens": 200
  }'
```

### Example: Check Performance

```bash
curl http://localhost:5413/stats | python3 -m json.tool
```

---

## Use with AI Coding Tools

### Aider

```bash
aider \
  --openai-api-base http://localhost:5413/v1 \
  --openai-api-key fake \
  --model openai/mlx-community/Qwen3.5-35B-A3B-4bit
```

The `openai/` prefix tells Aider's litellm backend to use the OpenAI protocol. The API key can be any string (unless you set `--api-key` on the server).

For token limit configuration, create `.aider.model.settings.yml` in your project:

```yaml
- name: openai/mlx-community/Qwen3.5-35B-A3B-4bit
  extra_params:
    max_tokens: 4096
  max_input_tokens: 32000
  max_output_tokens: 4096
```

### Other Tools

Any tool that supports a custom OpenAI base URL works: Cursor, Continue, Open WebUI, etc. Point it at `http://localhost:5413/v1`.

---

## Features

### SSD Expert Streaming

Run models larger than your RAM by memory-mapping expert weights from SSD. Instead of loading all parameters into memory, SwiftLM pages in only the active experts per token via the OS page cache. This is read-only I/O -- no SSD wear.

```bash
.build/release/SwiftLM \
  --model mlx-community/Qwen3.5-122B-A17B-4bit \
  --port 5413 \
  --stream-experts
```

This lets a 67GB model run on a 36GB machine. Speed is bottlenecked by SSD bandwidth (~5 GB/s on M-series) rather than GPU compute.

### TurboQuant KV Cache Compression

Compresses KV cache history to ~3.5 bits per token using PolarQuant + QJL. Useful for long-context (100k+) requests where KV cache would otherwise exhaust memory.

```bash
.build/release/SwiftLM \
  --model mlx-community/Qwen3.5-35B-A3B-4bit \
  --port 5413 \
  --turbo-kv
```

See [docs/turboquant_hybrid_architecture.md](docs/turboquant_hybrid_architecture.md) for the algorithm details.

### Thinking/Reasoning Mode

For models that support `<think>` tags (Qwen3.5, DeepSeek-R1, etc.), enable reasoning mode:

```bash
.build/release/SwiftLM --model mlx-community/Qwen3.5-35B-A3B-4bit --port 5413 --thinking
```

Reasoning content is returned in the `reasoning_content` field of the response, separate from the main `content`. Can also be enabled per-request via `"enable_thinking": true`.

### Layer Partitioning

Split model layers between GPU and CPU when a model almost fits in memory:

```bash
.build/release/SwiftLM --model mlx-community/Qwen2.5-72B-Instruct-4bit --port 5413 --gpu-layers 40
```

Use `--gpu-layers auto` to let the profiler decide based on available memory.

### Wisdom Auto-Calibration

On first run for each model/hardware combination, SwiftLM benchmarks different memory cache limits and picks the one that maximizes decode speed. Results are cached in `~/.swiftlm/wisdom/` and loaded instantly on subsequent runs.

Force re-calibration with `--calibrate`.

---

## CLI Reference

| Option | Default | Description |
|--------|---------|-------------|
| `--model` | (required) | HuggingFace model ID or local path |
| `--port` | `5413` | Port to listen on |
| `--host` | `127.0.0.1` | Host to bind |
| `--max-tokens` | `2048` | Default max tokens per generation |
| `--ctx-size` | model default | Context window size (enables sliding window cache) |
| `--temp` | `0.6` | Default sampling temperature |
| `--top-p` | `1.0` | Default nucleus sampling |
| `--repeat-penalty` | disabled | Repetition penalty factor |
| `--parallel` | `1` | Number of parallel request slots |
| `--thinking` | disabled | Enable thinking/reasoning mode |
| `--vision` | disabled | Enable VLM (vision-language model) mode |
| `--mem-limit` | system default | GPU memory limit in MB |
| `--api-key` | disabled | API key for bearer token auth |
| `--cors` | disabled | Allowed CORS origin (`*` for all) |
| `--gpu-layers` | all GPU | Number of layers on GPU (`auto` or integer) |
| `--stream-experts` | disabled | SSD expert streaming for MoE models |
| `--turbo-kv` | disabled | TurboQuant KV cache compression |
| `--prefill-size` | `512` | Chunk size for prefill evaluation |
| `--calibrate` | disabled | Force re-calibration of memory settings |
| `--info` | disabled | Profile memory requirements and exit |

---

## SwiftBuddy -- iOS App

A native iPhone/iPad companion app that downloads MLX models from HuggingFace and runs inference on-device.

- Chat UI with model picker
- Live download progress
- Model catalog with on-device RAM fit indicators
- HuggingFace search for `mlx-community` models

### Build & Run

```bash
cd SwiftBuddy
python3 generate_xcodeproj.py
open SwiftBuddy.xcodeproj
```

In Xcode: set your Team under Signing & Capabilities, select your device, and build (Cmd+R). The `.xcodeproj` is git-ignored since it contains your Team ID.

---

## Project Structure

```
Sources/SwiftLM/
  SwiftLM.swift              # CLI entry point (argument parsing)
  ServerBootstrap.swift       # Model loading, memory config, server startup
  Routes.swift                # HTTP router and endpoint registration
  Handlers/                   # Request handlers (chat, text, health, metrics)
  Streaming/                  # SSE formatting, thinking tag parser
  Caching/                    # Prompt cache (KV state save/restore)
  Models/                     # API types, server config
  Utilities/                  # Logging, concurrency, progress tracking
  Middleware/                  # CORS, API key auth

Sources/MLXInferenceCore/     # Shared inference library (iOS + macOS)
SwiftBuddy/                   # iOS app
```

---

## Logging

Logs go to both stdout and `~/.swiftlm/server.log`. Uses [swift-log](https://github.com/apple/swift-log) with debug, info, warning, and error levels.

Tail the log:
```bash
tail -F ~/.swiftlm/server.log
```

---

## Benchmarks

Run the automated benchmark suite:
```bash
./run_benchmark.sh
```

Tests generation speed and memory across context lengths (512, 40k, 100k tokens) with configurations: vanilla, SSD streaming, TurboQuant, and SSD + TurboQuant.

---

## Acknowledgments

- [mlx-swift](https://github.com/ml-explore/mlx-swift) -- Apple's Metal-accelerated ML framework for Swift
- [mlx-lm](https://github.com/ml-explore/mlx/tree/main/mlx_lm) -- Reference Python implementation for chunked-prefill architecture
- [flash-moe](https://github.com/danveloper/flash-moe) -- Inspired the SSD expert streaming design
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) -- Swift HTTP server
- [swift-transformers](https://github.com/huggingface/swift-transformers) -- HuggingFace tokenizers and model downloads
- [TurboQuant](https://arxiv.org/abs/2504.19874) -- KV cache compression algorithm (Zandieh et al.)

---

**License**: MIT
