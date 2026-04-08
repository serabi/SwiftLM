# Requirements: SwiftLM Modular Refactor

## Context

SwiftLM is a forked (serabi/SwiftLM from SharpAI/SwiftLM) native Swift inference server
for Apple Silicon that serves MLX models through an OpenAI-compatible REST API. The codebase
was largely AI-generated ("vibe-coded") and has accumulated significant technical debt.

## Goals

1. Make the codebase maintainable and understandable
2. Preserve all working features (SSD streaming, TurboQuant, prompt cache, Wisdom calibration)
3. Keep both macOS CLI and iOS app targets functional
4. Set up a clean foundation for future features (MCP server integration on iOS)
5. Keep OpenAI-compatible API endpoints stable (`/v1/chat/completions`, `/v1/completions`, `/health`)

## Functional Requirements

- Split monolithic Server.swift (2,279 lines) into focused modules
- Deduplicate tokenizer bridges shared between Server.swift and InferenceEngine.swift
- Replace unsafe `try!` / `[String: Any]` JSON patterns with Codable structs
- Replace 64 `print()` calls with structured logging (os.Logger)
- Extract prompt cache, thinking state tracker, and SSE formatting into own modules
- Extract CLI initialization logic into a ServerBootstrap
- Document the Calibrator/Wisdom algorithm and its magic numbers
- Audit CLI flags for dead/non-functional options

## Non-Functional Requirements

- No behavior changes to inference pipeline
- OpenAI API response format must remain compatible
- Both SwiftLM (macOS CLI) and SwiftBuddy (iOS app) must build
- No new dependencies added

## Constraints

- Cannot easily test inference correctness without running against a real model
- Hard-won bug fixes in the inference path (7 critical divergences from Python reference) must be preserved
- SharpAI forks of mlx-swift and mlx-swift-lm are required dependencies

## Scope

### In scope
- Server.swift decomposition
- Tokenizer bridge deduplication
- JSON safety (Codable conversion)
- Structured logging
- Calibrator documentation
- CLI flag audit
- Health endpoint cleanup

### Out of scope
- MCP server integration (future feature)
- Rewriting MLX inference layer
- Adding tests (future work)
- Upstream PR compatibility
- New features of any kind
