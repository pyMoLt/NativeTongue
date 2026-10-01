# NativeTongue

**Private, on-device dictation for macOS.** NativeTongue is a Swift and SwiftUI menu-bar app for German and English dictation, spoken text commands, terminology, and audio or video transcription. It is the continuation of the Local ASR project and a fork of the legacy Swift app from Hex.

The app is under active development. Its current target is Apple Silicon on macOS 26 or newer. Development and hands-on checks have focused on an M5 Pro with 48 GB of unified memory.

## What it does

- **Normal and Literal dictation.** Normal mode is designed for everyday text and code. Literal mode turns explicitly spoken punctuation and commands into formatted text.
- **Dictation Box.** Review and edit a transcript before inserting it. Format text, inspect terminology suggestions, spell words aloud, or add corrections to your lexicon.
- **Local speech models.** Choose among Whisper, Parakeet, Qwen3-ASR, Canary, Cohere and Apple SpeechAnalyzer options in the model catalog. Model support and language coverage vary; the catalog shows each model's backend, size, precision, license and capabilities.
- **Terminology tools.** Keep personal vocabulary and optionally install word packs for medical, Latin-anatomy and technical terms.
- **Audio and video files.** Queue supported media for transcription, optionally separate speakers, review the result, and export text, Markdown, SRT or VTT.
- **Menu-bar controls and history.** Switch modes, inspect the current state and copy recent text. Saving dictation history is optional.

## Privacy and network use

Speech recognition and text processing run on the Mac with the selected local model. NativeTongue has no cloud speech-recognition service, telemetry or automatic updater.

Network access is used only when you explicitly start an installation, such as downloading a model, a word pack, Apple speech assets or speaker-separation models. Those downloads are stored locally and used for on-device processing. During inference, the app does not send audio or transcripts to a server.

The app can save local recovery audio while recording. Transcript history is off by default and can be enabled in Settings. File transcription exports are written only when you choose a destination.

## Requirements

- Apple Silicon Mac
- macOS 26 or newer
- Full Xcode.app for development and building
- Microphone permission for dictation
- Accessibility permission for system-wide text insertion
- Additional disk space for the model and optional word packs you install

Models are not included in the app bundle. Download only the models you want from the in-app model screen.

## Build and test

Open Hex.xcodeproj in Xcode and build the **Hex** scheme. The app's displayed name is **NativeTongue**; the scheme and module retain their legacy Hex names.

The verified commands used for development are:

~~~bash
# Debug app build
xcodebuild -scheme Hex -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalASR-DD \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build

# HexCore tests
swift test --package-path HexCore --scratch-path /private/tmp/LocalASR-HexCore
~~~

To run one app test suite, replace SuiteName with the XCTest suite name:

~~~bash
xcodebuild test -scheme Hex \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalASR-DD \
  -skipMacroValidation CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  -only-testing:HexTests/SuiteName
~~~

## Current validation

The app has been built and run on Apple Silicon. Recent checks include the dictation pipeline, Dictation Box, terminology, file transcription and several installed model engines. The full test suite still has environment-related failures and skipped model-backed tests; a complete microphone, permission and text-insertion check depends on the permissions granted on the Mac. Treat this repository as an actively developed project rather than a finished, broadly validated release.

## Project layout

- Hex/ — macOS app and UI
- HexCore/ — reusable dictation logic and tests
- Packages/LocalASRSpeech/ — vendored Qwen3-ASR runtime
- Hex/Resources/Data/models.json — model catalog
- LICENSE — project license

Model weights and their terms are provided by their respective authors. Check each model's license in the in-app catalog before installing or using it.
