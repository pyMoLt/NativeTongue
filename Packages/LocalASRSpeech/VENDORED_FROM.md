# Vendored Qwen3-ASR runtime

This package contains the smallest buildable subset of soniqo/speech-swift required by NativeTongue's local Qwen3-ASR MLX backend.

- Upstream tag: v0.0.23
- Upstream commit: c1aa219bc2284239ff6917d675a3e1978c840260
- License: Apache License 2.0 (see LICENSE)
- Vendored targets: AudioCommon, MLXCommon and batch-mode Qwen3ASR
- Excluded: servers, command-line tools, text-to-speech, translation, streaming/VAD, Core ML Qwen experiments and the upstream WhisperKit comparison target

The upstream Swift sources are kept unmodified. NativeTongue adds a small local MLX memory-control helper and a purpose-built Package.swift that pins only dependencies required by this app. When updating the upstream snapshot, compare every upstream source file and re-run the package build, offline-manifest tests, app tests and app Release build.

## NativeTongue changes

- 2026-09-26, NativeTongue 2.0: removed unused AudioCommon files for TTS, playback and system-audio features. The app deployment target was raised to macOS 26.
- 2026-09-26, NativeTongue 2.0: added suppressed-token support to Qwen3 decoding and punctuation-token identification for Literal mode.
- Sources/Qwen3ASR/MLXMemoryControl.swift: NativeTongue memory-cache controls; not present upstream.
