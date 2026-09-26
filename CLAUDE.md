# Local ASR — Notes for Coding Agents

Local ASR is a private, fully offline macOS menu-bar dictation app (fork of Hex v0.8.5, Swift/SwiftUI/TCA). Target: MacBook Pro M5 Pro, macOS 26+ (runs on macOS 27, Xcode 27). Repo: `github.com/pyMoLt/local-asr` (private); original Hex is remote `upstream`.

**The binding implementation plan for version 2.0 lives outside this repo:**
`../local-asr-docs/03-version-2/LOCAL_ASR_V2_UMSETZUNGSPLAN.md`. Read it before changing anything. Keep `../local-asr-docs/05-logs/LOCAL_ASR_WORK_LOG.md` (current task) and `../local-asr-docs/05-logs/PROGRESS-LOG.md` (append-only steps + decisions) up to date at every significant step. Project documents are intentionally not committed here.

## Build & test

```bash
# App (Debug, arm64)
xcodebuild -scheme Hex -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalASR-DD -skipMacroValidation -skipPackagePluginValidation CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build

# Pure logic tests (HexCore)
swift test --package-path HexCore --scratch-path /private/tmp/LocalASR-HexCore

# App tests (one suite)
xcodebuild test -scheme Hex -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalASR-DD -skipMacroValidation CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual -only-testing:HexTests/<Suite>
```
Harmless noise: CoreDevice/CoreSimulator version warnings. With `-quiet`, always confirm success via `** BUILD SUCCEEDED **` or `xcresulttool`.

## Architecture (current, V2 in progress)

- TCA features in `Hex/Features/*` (`AppFeature`, `TranscriptionFeature`, `SettingsFeature`, `AudioImportFeature`, `HistoryFeature`).
- Clients in `Hex/Clients/*`: `TranscriptionClient` (engine dispatch + explicit model installation), `ParakeetClient`, `QwenASRClient`, `AdditionalFluidAudioASRClient` (Canary, Omi), `RecordingClient`/`SuperFastCaptureController` (16 kHz capture), `PasteboardClient`, `KeyEventMonitorClient`.
- Pure logic in `HexCore` (settings schema + migration, hotkey processing, formatting). New deterministic V2 logic (segmentation, commands, text pipeline, lexicon) goes into `HexCore` with unit tests.
- Model catalog: `Hex/Resources/Data/models.json` + `Hex/Models/LocalASRModelCatalog.swift`.
- Vendored Qwen3-ASR runtime: `Packages/LocalASRSpeech` (see `VENDORED_FROM.md`).
- Pinned: WhisperKit 0.15.0, FluidAudio `21493f8`, swift-transformers 1.1.6, mlx-swift 0.31.4.

## Rules

- Offline by default: no network except explicit, user-started installs (models, lexicon packs). Never download inside inference paths; never add silent fallbacks.
- At most one ASR model resident.
- Privacy: log via `HexLog` only; never log transcripts, audio, lexicon contents, clipboard contents or file names in clear text (`privacy: .private`).
- Hotkey semantics (`HotKeyProcessor`, `docs/hotkey-semantics.md`) are stable — don't change them without a plan item.
- No Sparkle/auto-update, no telemetry, no cloud ASR.
- Commits: small, descriptive, author pyMoLt; work on `v2/<phase>` branches; no force-push.
