# NativeTongue 3.0.0

## New in 3.0

- **New look** — a calm colour field with a floating sidebar, glass surfaces and one consistent style on every page, in the menu bar panel, the dictation box and the recording pill. New app icon.
- **Appearance** — light, dark or system; accent colour; glass strength; colour field and motion; text size that follows macOS or is set by hand. The window keeps a sensible minimum size for every text size.
- **AI styles** — Clean up, Clean sentences, Rewrite as task, Key facts, E-mail, Short message, Note, Prompt and your own styles, for automatic clean-up, the box ✨, files and Command Mode. Tell the AI once what matters to you.
- **Profiles** — Mail, Coding, AI prompt, Medical or your own: mode, vocabulary, AI style and context per app, picked by the app you dictate into.
- **Command Mode** — select text, hold the Command Mode key and say what to do with it.
- **Context** — optional and off by default: the app name, or short hints from the text before the cursor (names, terms, language, list style), analysed on this Mac and never stored.
- **Better dictation** — correction commands, self-corrections ("no, I mean …"), times, money, ordinals and phone numbers, text snippets, spoken punctuation in Normal mode, phonetic term hints and learning from your corrections in the box.
- **Recording key** — hold to talk or tap to toggle.
- Many fixes for streaming, model loading and memory.

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
