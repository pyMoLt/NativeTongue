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
- 2026-10-15, NativeTongue 3.2: added `Sources/CoreAISpeechVendored` from apple/coreai-models (commit 9db747612f972001279f02adb04d3ef982310d0e, BSD-3-Clause) for the experimental Core AI backend (macOS 27). Changes: `@available(macOS 27.0, iOS 27.0, *)` on every top-level declaration (the package and the app stay at macOS 26), `import CoreAIShared` removed. The target disables CoreAI autolinking and weak-links the framework, so the app still launches on macOS 26.
- 2026-10-15, NativeTongue 3.2: added `Sources/CoreAIQwenASRVendored` for Qwen3-ASR 1.7B on Core AI (macOS 27): the language-model engine of john-rocky/coreai-models 0.2.4-zoo (commit f7a75ec0f89fab451d277572afe8995b7ef768c1, BSD-3-Clause; needed for `StaticInputBuffer`, not in apple/coreai-models) and the Qwen3-ASR runtime of mattt/coreai-kit (commit bebe09a050c144034c169af2074fda47fb7ba326, BSD-3-Clause). Removed: guided generation (xgrammar C++ dependency) incl. the constrained-decoding strategies and the corresponding methods of `CoreAIPipelinedEngine`, and the FoundationModels `LanguageModel` adapter (`CoreAILanguageModel.swift`, `ModelResources.swift`). Same availability marking and weak-linking as `CoreAISpeechVendored`.
