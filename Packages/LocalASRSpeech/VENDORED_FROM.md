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

## Local changes

- 2026-09-26 (Local ASR V2, phase 0): removed unused `AudioCommon` files that
  belong to TTS/playback/system-audio features (`AudioIO.swift`,
  `StreamingAudioPlayer.swift`, `SystemAudioTap.swift`,
  `HindiEmotionTTSCatalog.swift`, `PipelineLLM.swift`). Platform raised to
  macOS 26 to match the app.
- 2026-09-26 (Local ASR V2, phase 2): `Qwen3DecodingOptions.suppressedTokenIDs`
  (masked to -inf in `pickNextToken`; disables the greedy fast path when
  non-empty), `Qwen3Tokenizer.punctuationTokenIDs()` and
  `Qwen3ASRModel.punctuationTokenIDs()` for literal-mode punctuation masking.
- `Sources/Qwen3ASR/MLXMemoryControl.swift`: NativeTongue-Ergänzung (Cache-Limit setzen, Cache leeren) – nicht upstream.
