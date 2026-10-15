# Third-party code in LocalASRSpeech

| Folder | Source | License |
|---|---|---|
| `Sources/Qwen3ASR`, `Sources/AudioCommon`, `Sources/MLXCommon`, `Sources/CohereTranscribeASR` | soniqo/speech-swift (see file headers) | Apache-2.0 |
| `Sources/VoxtralRealtime` | Blaizzy/mlx-audio-swift @ 8d86630 (`MLXAudioSTT/Models/VoxtralRealtime`, `melFilters` from `MLXAudioCore/DSP.swift`), trimmed to the streaming session; offline generate/VAD/Hub download removed | MIT, © 2025 Prince Canuma |
| `Sources/CoreAISpeechVendored` | apple/coreai-models @ 9db7476 (`swift/Sources/CoreAISpeech` unchanged; `swift/Sources/CoreAIShared` Runtime/Bundle/Logger) — every top-level declaration marked `@available(macOS 27.0, iOS 27.0, *)`, `import CoreAIShared` removed (same module) | BSD-3-Clause, © 2026 Apple Inc. (`Sources/CoreAISpeechVendored/LICENSE-coreai-models.txt`) |
| `Sources/CoreAIQwenASRVendored` | john-rocky/coreai-models @ f7a75ec (tag 0.2.4-zoo, fork of apple/coreai-models: `CoreAILanguageModels` without guided generation/xgrammar and without the FoundationModels adapter, `CoreAILMCommon`, `CoreAIShared` Runtime/Bundle/Logger/Image/Video) and mattt/coreai-kit @ bebe09a (`ASR/ASRRuntime`, `ASRArchitecture`, `ASRPromptRenderer`, `Audio/AudioMelPreprocessor` + `mel_filters.f32`, `GraphBundle`, `CoreAIKitVision/GraphModel`, `TensorValue`, excerpts in `Kit/KitSupport.swift`) — every top-level declaration marked `@available(macOS 27.0, iOS 27.0, *)` | BSD-3-Clause (`LICENSE-coreai-models-zoo.txt` © 2026 Apple Inc., `LICENSE-coreai-kit.txt`) |
