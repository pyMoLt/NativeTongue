# NativeTongue changelog

This file records NativeTongue application changes. The app version is set in the Xcode project; the current development snapshot is 2.0.0 (build 200).

## 2.0.0 — Development snapshot

### Added

- Normal and Literal dictation modes with German and English spoken commands.
- Pause-based utterance segmentation and deterministic command classification in HexCore.
- A structured Dictation Box with rich text, Markdown/plain-text output, correction suggestions, re-dictation, spelling mode and explicit insert/discard controls.
- Local vocabulary entries, aliases and file-imported domain packs.
- File transcription queue for audio/video, segment editing, optional local speaker separation, and TXT, Markdown, SRT and VTT export.
- Menu-bar panel, recording HUD, model management, settings transfer and optional transcript history.
- Model catalog options using WhisperKit/Core ML, FluidAudio/Core ML, Qwen3-ASR/MLX, Cohere/MLX and Apple SpeechAnalyzer.

### Changed

- Audio and transcripts remain on-device during local inference. Model and speech assets are installed only after an explicit user action.
- Model downloads and inference are separate operations; an inference request does not silently fetch missing weights.
- Model selection unloads the previous ASR backend before loading the next one; idle unloading can release memory.
- Clipboard insertion restores the prior clipboard after the target app reads the text.

### Validation notes

- The latest detailed audit recorded successful app builds and several focused suites.
- The full app test suite was not fully green in that audit: UI snapshot writes failed in the test sandbox and model-backed tests were skipped. A separate Swift Testing helper crashed after the HexCore XCTest portion passed.
- Microphone, Accessibility and system-wide insertion behavior still requires manual validation on a Mac with the relevant permissions.

These notes describe the current NativeTongue application. They do not include inherited release history from other products.
