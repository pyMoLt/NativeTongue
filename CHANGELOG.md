# Changelog

All notable NativeTongue changes. The app version is set in the Xcode project.

## 3.2.0

### Added

- **Literal fine-tuning** (module `LiteralTuning`, Literal mode only), one profile per engine family:
  - Whisper writes no punctuation of its own: every mark, hyphen, bracket or quote in the text comes from a spoken command.
  - Structural commands ("Neuer Absatz", "Neue Zeile") need only the pause before them, or none right after a spoken mark.
  - "Spiegelstrich" works anywhere, and commands split by a pause are joined again.
  - Stricter article rule ("Kleber mit Punkt" → "mit.", "Ein/Aus", "um Punkt 8").
  - Strong self-corrections ("…, nein ich meine …") work across a model period.
  - Clean-up of hallucinated "you"/"Thank you" and CJK characters.
  - Dates "3. März", money "1.250 €", decimals "2,5 mg".
  - Qwen3-ASR decodes longer segments; every other engine gets the engine-independent rules.
- **Gap fill for Whisper**: passages Whisper skips after a pause (for example a word list at the end) are decoded again. Normal and Literal mode; switch under Models → Advanced, on by default.
- **Core AI models (experimental, macOS 27 only)**:
  - **Parakeet Ultra (Core AI)** with real live streaming and about a third of the memory. Available in Normal, Literal (limited) and Streaming mode.
  - **Qwen3-ASR 1.7B (Core AI)**: as accurate as the MLX version with about 0.8 GB instead of 7 GB, about half as fast. Not well suited to Literal.
  - Both run on Apple's Core AI runtime (vendored `CoreAISpeech`, BSD-3-Clause). On macOS 26 they show "Needs macOS 27"; the app itself still runs on macOS 26.
- **Whisper Large v3 Turbo German** (6-bit, Core ML) and the text models MiniCPM5 1B/2B, G9v3 3B and Granite 4.2 3B (untested model cards).
- **Text models for maximum quality**: Gemma 4 12B (8-bit, about 13 GB) and Qwen3.5 4B (8-bit, about 5 GB), pinned MLX checkpoints with untested model cards.
- Model cards of the Core AI models show the measured accuracy, memory and speed.

### Changed

- Removed the legacy Whisper Turbo artifact and the 4-bit compressed Turbo from the catalog; saved selections move to Whisper Large v3 Turbo.
- Removing a Core AI model also clears its Core AI specialization cache.

### Fixed

- Qwen3-ASR (MLX) hands its memory back when it unloads.

## 3.0.0

### Added

- **Flow design**: a colour field behind every window, a floating glass sidebar with a gliding selection, one set of components for every page, the menu bar panel, the dictation box and the recording pill. New app and menu bar icon.
- **Appearance page**: light, dark or system; accent colour; glass strength; colour field; motion; text size that follows the macOS setting or is fixed (XS–XXL). Text, icons and rows scale together, and the window keeps a minimum size that grows with the text.
- **AI styles**: Clean up, Clean sentences, Rewrite as task, Key facts, E-mail, Short message, Note, Prompt and custom styles, shared by the automatic step, the box ✨, file transcription and Command Mode. A personal "What matters to me" note is added to every prompt; prompts are editable under Advanced.
- **Profiles**: General, Mail, Coding, AI prompt, Medical and custom profiles. Each sets vocabulary domain, word packs, mode, punctuation, code formatting, AI step, AI style and context, and is picked by the app you dictate into.
- **Command Mode**: select text, hold the Command Mode key and speak an instruction; the selection is read via Accessibility (or a restored ⌘C) and replaced with the result.
- **Context from the text field** (off by default): app name only, or short hints analysed on the Mac from the text before the cursor (continuation, terms and names, form of address, language, app type, list style). The text itself is never stored, logged or passed to the AI.
- Correction commands, self-corrections, sturdier Literal mode, spoken punctuation in Normal mode, numbers for times, money, ordinals, phone and house numbers, text snippets, phonetic term hints and learning from box corrections.
- Recording key: hold to talk or tap to toggle.

### Fixed

- Streaming lifecycle: session ids, stopping during model load, ordered sessions and held text.
- Number formatter overflow on repeated hundreds.
- One model job at a time; leftover temporary data is cleaned up; lower idle energy use.
- History entries no longer keep the insertion space.

## 2.5.0

### Added

- **Streaming mode** (off by default): words are typed into the frontmost app while you speak. Native streaming with Nemotron 3.5 Multilingual and Voxtral Mini 4B Realtime, Apple SpeechAnalyzer, and block-per-pause streaming for other models.
- **AI post-processing** (off by default): a local MLX language model cleans up the text or rewrites it as a task, automatically or via ✨ in the dictation box. A safety check keeps the original when numbers, doses, terms or negations would change.
- Redesigned model cards with per-mode recommendations.

### Changed

- A second press of the dictation key during processing is ignored; Esc cancels.
- Decoder repetition loops are collapsed before commands are applied.
- Typing fallback uses Unicode key events.

## 2.0.0

### Added

- Normal and Literal dictation modes with German and English spoken commands.
- Pause-based segmentation and deterministic command classification.
- Dictation Box with rich text, Markdown and plain-text output, suggestions, re-dictation and spelling mode.
- Personal vocabulary, aliases and importable domain packs.
- File transcription with optional speaker separation and TXT, Markdown, SRT and VTT export.
- Menu bar panel, recording HUD, model management, settings transfer and optional history.

### Changed

- Audio and transcripts stay on the Mac. Models are installed only after an explicit user action and are never fetched during inference.
- One speech model is resident at a time; idle unloading frees memory.

## 1.0.0

First version as an independent app ("Local ASR"): own app identity, curated offline model catalog (Whisper, Parakeet, Qwen3-ASR and others) with explicit installation, normal and literal dictation, audio file import, transcript history off by default and no update or telemetry paths.
