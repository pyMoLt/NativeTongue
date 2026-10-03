# NativeTongue 2.5.0

## New in 2.5

- **Streaming** — a third mode: words appear in your app while you speak. Pause, type a comma or fix a word, then keep talking. Best with Nemotron 3.5 or Voxtral Realtime; Whisper and Parakeet type a block after each pause.
- **AI post-processing** — optional, fully local. Clean up dictations automatically or with ✨ in the dictation box (⇄ shows what changed). A safety check keeps your original when numbers, doses or terms would change.
- **Esc** cancels the current dictation. Pressing the dictation key again while text is still being processed no longer cancels it.
- Clearer model cards with recommendations per mode.

# NativeTongue 2.0.0

NativeTongue is a local macOS dictation application for German and English.

## Dictation

- **Normal** mode for natural text and code; **Literal** mode for explicit spoken punctuation and formatting.
- Pause-based commands for new paragraphs, line breaks, editing and formatting.
- Local number/unit formatting and vocabulary correction.
- Model capability badges distinguish reliable Literal engines from engines with limited or unverified punctuation control.

## Dictation Box

- Review, edit and format text before inserting it.
- Use rich text, Markdown or plain text output.
- Inspect vocabulary suggestions, re-dictate a selection or use spelling mode.
- Confirm or discard explicitly; drafts are stored locally.

## Models and vocabulary

- Local Whisper, Parakeet, Qwen3-ASR, Cohere, Canary, Omi Medical and Apple SpeechAnalyzer options.
- Install model assets only after selecting an explicit Install action.
- Keep personal vocabulary and import optional word packs from local files.

## Files and history

- Queue audio and video for local transcription.
- Optionally separate speakers using installed local Core ML assets.
- Edit segments and export TXT, Markdown, SRT or VTT.
- Transcript history is optional and off by default.

## Privacy

Speech, transcripts and vocabulary are processed locally. NativeTongue has no cloud transcription endpoint, telemetry service or automatic updater. Network connections are used for user-started model and speech-asset installation only.
