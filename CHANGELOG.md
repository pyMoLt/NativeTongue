# NativeTongue changelog

This file records NativeTongue application changes. The app version is set in the Xcode project; the current development snapshot is 2.5.0 (build 250).

## 2.5.0 — Development snapshot

### Added

- **Streaming mode** (off by default): a third mode next to Normal and Literal. Words are typed into the frontmost app while you speak; pause, type or fix something and keep talking. Native streaming with Nemotron 3.5 Multilingual (Neural Engine) and Voxtral Mini 4B Realtime (MLX), Apple SpeechAnalyzer, and block-per-pause streaming for Whisper, Parakeet and other models. Optional streaming into the dictation box in Literal mode.
- **AI post-processing** (off by default): a local MLX language model cleans up the text (word errors, punctuation, capitalisation, paragraphs, spelled letters) or rewrites a spoken train of thought as a clear task. Automatic after each dictation or via the ✨ button in the dictation box, which then turns into a before/after comparison. A safety check (numbers, doses, units, vocabulary terms, negations, code, length) keeps the original text when something looks wrong; the pill shows ⚠︎. Curated model list plus Hugging Face links, editable prompts, memory policy.
- Redesigned model cards with descriptions, per-mode recommendations and streaming badges.

### Changed

- A second press of the dictation key while a dictation is still being processed is ignored; Esc cancels (and no longer reaches the frontmost app while a dictation is active).
- Decoder repetition loops are collapsed before commands are applied.
- Typing fallback uses Unicode key events instead of AppleScript.
- Debug builds run without App Sandbox like the direct release build; the full test suites run green.

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
