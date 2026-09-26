# Vendored Qwen3 ASR runtime

This package contains the smallest buildable subset of
[`soniqo/speech-swift`](https://github.com/soniqo/speech-swift) needed for the
local Qwen3-ASR MLX backend.

- Upstream tag: `v0.0.23`
- Upstream commit: `c1aa219bc2284239ff6917d675a3e1978c840260`
- License: Apache License 2.0 (see `LICENSE`)
- Vendored targets: `AudioCommon`, `MLXCommon`, and batch-mode `Qwen3ASR`
- Intentionally excluded: servers, command-line tools, TTS, translation,
  streaming/VAD, Core ML Qwen experiments, and the upstream WhisperKit
  comparison target.

The Swift sources are copied without local edits. The local `Package.swift` is
purpose-built to pin only the dependencies required by this app. When updating
the upstream snapshot, compare every source file and re-run the package build,
offline-manifest tests, app tests, and app Release build before changing the
commit recorded above.
