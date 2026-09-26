# Changelog

## 2.0.0 (in development)

### Dictation
- Two modes: **Normal** (natural text for chats and AI agents) and **Literal** (only spoken punctuation, for precise, demanding texts).
- The whole recording is transcribed once after you stop; audio pauses decide whether “new paragraph”, “scratch that” and similar phrases are commands.
- Spoken punctuation, formatting and editing commands in German and English.
- Formatting for AI agents: file names, camelCase/snake_case, backticks, slash commands.
- Numbers, units and dates are formatted (“two point five milligrams” → 2.5 mg).

### Dictation box
- Collect several dictations, edit, format (bold, italic, headings, lists) and insert only with ✓.
- Hover a word for the five most similar vocabulary terms; re-dictate a selection; spelling mode.
- Learns from your corrections; unsent text survives a crash.

### Vocabulary
- Your own terms with known misrecognitions, plus optional domain word packs (medicine, anatomy, technology).
- Conservative automatic correction that never touches ordinary words.

### Models
- Whisper (Large v3, Turbo), Parakeet (v2, v3, Ultra), Qwen3-ASR, Canary, Cohere Transcribe (MLX), Apple SpeechAnalyzer.
- Punctuation suppression for Literal mode on every engine; one model in memory, unloaded when idle.

### Interface
- Liquid Glass menu bar panel, recording HUD and main window; new app icon.
- The clipboard is fully restored after every insertion.

---

Based on [Hex](https://github.com/kitlangton/Hex) 0.8.5 by Kit Langton (MIT License).
