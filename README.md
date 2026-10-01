# NativeTongue

**Private, on-device dictation for macOS.** NativeTongue turns speech into text in German and English, supports spoken editing and formatting commands, and transcribes audio or video files. It is built with Swift, SwiftUI, AppKit and The Composable Architecture.

The app targets Apple Silicon and macOS 26 or newer. Development and hands-on validation have focused on an M5 Pro with 48 GB of unified memory. NativeTongue is under active development; it is not a finished, broadly validated public release.

## Features

### Dictation

- A configurable global hotkey supports press-and-release dictation and a double-tap recording lock.
- **Normal mode** is intended for natural text, everyday writing and code.
- **Literal mode** suppresses model-generated punctuation where the selected engine supports it. Spoken punctuation and commands produce the requested characters.
- German and English commands can insert paragraphs and lines, edit recent text, format the Dictation Box and express common punctuation.
- Audio pauses, rather than transcript punctuation, determine command boundaries. The default command pause is 450 ms.
- Number and unit formatting, optional AI-agent/code formatting, and vocabulary correction run locally.
- The optional **Dictation Box** collects dictations for review. It supports rich text, Markdown and plain-text output, suggestions, re-dictation of a selection, spelling mode, undo and explicit insert or discard actions.
- NativeTongue restores the previous clipboard contents after text insertion.

### Models

The bundled model catalog lists each model's backend, language coverage, precision, estimated storage, license, capabilities and Literal-mode rating.

| Model family | Local runtime | Current catalog options |
|---|---|---|
| Whisper | WhisperKit with Core ML | Tiny, Base, Large v3, Large v3 Turbo, including catalogued precision variants |
| Parakeet | FluidAudio with Core ML | TDT v2, TDT v3 and Ultra |
| Qwen3-ASR | MLX | 0.6B and 1.7B |
| Cohere Transcribe | MLX | 2B 8-bit |
| Canary and Omi Medical | FluidAudio with Core ML | Canary 1B v2 and English clinical Omi |
| Apple SpeechAnalyzer | Apple Speech framework | On-device German and English dictation assets |

Model downloads are explicit user actions in the Models screen. Inference requires installed assets and does not fetch missing model files. At most one ASR model is kept resident; an idle timeout can unload it.

### Vocabulary and files

- Add personal terms and aliases, or import optional vocabulary packs for medicine, anatomy and technology. Packs are read from files selected by the user.
- Import and queue audio or video files, review the transcript, optionally separate speakers, and export TXT, Markdown, SRT or VTT.
- Transcript history is off by default. If enabled, it is stored locally. Temporary recovery audio is also local.

### Interface

NativeTongue is a menu-bar app with a main window for dictation, models, commands, vocabulary, files, history and settings. A recording HUD and menu-bar panel show the current state and recent transcript.

## Requirements and permissions

- Apple Silicon Mac running macOS 26 or newer.
- Microphone permission for voice capture.
- Accessibility permission for system-wide text insertion. macOS may also request Input Monitoring for the global hotkey.
- Full Xcode.app to build the app from source.
- Model weights are separate downloads; storage requirements depend on the chosen models and optional speaker-separation assets.

## How it works

1. The hotkey starts local audio capture. Audio is converted to mono 16 kHz samples for the recognition pipeline.
2. After recording stops, the session runner segments speech using measured audio pauses.
3. A local engine transcribes the recording. Engines with word timings can transcribe the whole clip once and align words to pauses; engines without them are called per utterance.
4. Deterministic command parsing, punctuation handling, number formatting and the local lexicon build the final document.
5. Normal mode inserts text directly. Literal mode can open the Dictation Box for review before insertion.

The app is divided between the SwiftUI/AppKit application and the reusable HexCore logic package. Detailed component responsibilities are in [docs/architecture.md](docs/architecture.md).

## Network and privacy

NativeTongue has no app-owned transcription API, cloud speech service, telemetry service or automatic updater. It does not send recorded audio or transcript text to a server during local inference.

Network access is used only when the user starts an installation:

| Destination or service | Purpose | Started by |
|---|---|---|
| [Hugging Face Hub](https://huggingface.co) and its file-delivery redirects | Model weights and tokenizer assets specified by the bundled catalog or a model adapter | Install a model in the app |
| FluidAudio ModelHub, which uses Hugging Face by default | Parakeet, Canary, Omi and optional speaker-separation model assets | Install that model or speaker-separation support |
| Apple Speech AssetInventory | Apple-managed SpeechAnalyzer assets for supported languages | Install Apple SpeechAnalyzer in the model screen |
| No network service | Vocabulary packs are imported from local files; there is no pack-fetch endpoint | Choose files in the import dialog |

These downloads reveal normal connection metadata and the requested public model or asset to the respective provider. Downloaded assets are used locally afterward. See [docs/network-and-privacy.md](docs/network-and-privacy.md) for the data-flow audit and boundaries.

## Build and test

Open the Xcode project and build the NativeTongue app target. The app target uses retained internal Xcode identifiers; the displayed app name is NativeTongue and the bundle identifier remains com.localasr.LocalASR to preserve existing settings and installed models.

~~~bash
# Debug app build (Apple Silicon)
xcodebuild -scheme Hex -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NativeTongue-DD \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build

# Pure logic package tests
swift test --package-path HexCore --scratch-path /private/tmp/NativeTongue-HexCore
~~~

To run one app test suite, replace SuiteName with its XCTest suite name:

~~~bash
xcodebuild test -scheme Hex \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NativeTongue-DD \
  -skipMacroValidation CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -only-testing:HexTests/SuiteName
~~~

This repository currently has no tracked GitHub Actions workflow files. It also does not contain a supported one-command release packager or an automatic update service. See [docs/release-process.md](docs/release-process.md) before preparing a distributable build.

## Validation status

The application has been built and run on Apple Silicon. Core logic, Dictation Box, terminology, file handling and several installed-model paths have been exercised. The latest full audit found environment-related test failures and skipped model-backed tests; it did not complete a microphone, permission and system-wide insertion check. See [docs/release-pipeline-status.md](docs/release-pipeline-status.md) for the current validation and release status.

## Project map

- Hex/ — SwiftUI/AppKit application, TCA features and model adapters (internal target name)
- HexCore/ — dictation pipeline, hotkey logic, command grammar, lexicon and unit tests
- HexTests/ — application feature and integration tests
- Packages/LocalASRSpeech/ — vendored Qwen3-ASR MLX runtime
- Hex/Resources/Data/models.json — bundled model catalog
- docs/ — architecture, privacy, hotkey, audio-preparation and release documentation
- CHANGELOG.md and Hex/Resources/changelog.md — repository and in-app NativeTongue notes

NativeTongue's Swift application code is licensed under MIT. Model weights and third-party runtimes have separate terms; check the model catalog before installing a model.
