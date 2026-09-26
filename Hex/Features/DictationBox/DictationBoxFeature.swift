import AppKit
import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore

private let boxLogger = HexLog.transcription

/// Dragon-Medical-like dictation box (plan 5.8): dictations collect here, can be
/// edited, formatted and corrected, and are inserted into the target app only
/// on ✓. Enter/Escape never confirm or discard.
@Reducer
struct DictationBoxFeature {
  struct LearnCandidate: Equatable, Identifiable {
    let id = UUID()
    var original: String
    var replacement: String
    var isSelected = true
  }

  struct SuggestionState: Equatable {
    var range: NSRange
    var word: String
    /// Original spelling when the word was replaced automatically.
    var original: String?
    var suggestions: [Suggestion] = []
    var isLoading = true
  }

  enum Phase: Equatable {
    case editing
    /// After ✓: offer manual corrections for the lexicon.
    case learning
  }

  @ObservableState
  struct State: Equatable {
    var isPresented = false
    var phase: Phase = .editing
    var text = BoxText()
    /// Bumped on programmatic changes so the editor replaces its content.
    var revision = 0
    var selection = NSRange(location: 0, length: 0)
    var targetBundleID: String?
    var targetAppName: String?
    var mode: DictationMode = .literal
    var language = "de"
    /// Selection frozen at recording start: the next result replaces it.
    var replacementRange: NSRange?
    var spellingMode = false
    var lastAction = ""
    var audioURLs: [URL] = []
    /// Text before each dictation, for „streich das“ across dictations.
    var snapshots: [BoxText] = []
    var learnCandidates: [LearnCandidate] = []
    var suggestion: SuggestionState?
    var isConfirmingDiscard = false
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isDictationBoxPresented) var isDictationBoxPresented: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

    var baseFont: NSFont {
      BoxTextStyle.baseFont(name: hexSettings.boxFontName, size: hexSettings.boxFontSize)
    }

    var wordCount: Int { BoxTextEditing.wordCount(text.string) }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case present(targetBundleID: String?, targetAppName: String?, mode: DictationMode)
    case restoreDraft(BoxText)
    case recordingStarted
    case dictationFinished(DictationSessionOutput, URL)
    // Editor
    case textEdited(BoxText, selection: NSRange)
    case selectionChanged(NSRange)
    case wordHovered(NSRange)
    case suggestionsLoaded([Suggestion], for: NSRange)
    case applySuggestion(String)
    case revertCorrection
    case prepareRedictation
    case spellSelection
    case addHoveredWordToLexicon
    case dismissSuggestions
    // Toolbar
    case toggleBold
    case toggleItalic
    case toggleHeading
    case toggleBullets
    case quoteSelection
    case cycleCase
    case toggleSpellingMode
    case setFont(String)
    case setFontSize(Double)
    case setFormat(OutputFormat)
    case setLanguage(String?)
    // Finish
    case confirmTapped
    case discardTapped
    case discardConfirmed
    case learnConfirmed
    case learnSkipped
    case close
  }

  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.lexicon) var lexicon

  private enum CancelID { case suggestions, draft }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case let .present(targetBundleID, targetAppName, mode):
        guard !state.isPresented else { return .none }
        state = State()
        state.isPresented = true
        state.targetBundleID = targetBundleID
        state.targetAppName = targetAppName
        state.mode = mode
        state.language = state.hexSettings.outputLanguage ?? "de"
        state.$isDictationBoxPresented.withLock { $0 = true }
        state.lastAction = targetAppName.map { "Target: \($0)" } ?? ""
        return .run { _ in await MainActor.run { NotificationCenter.default.post(name: .presentDictationBox, object: nil) } }

      case let .restoreDraft(text):
        state = State()
        state.isPresented = true
        state.text = text
        state.revision += 1
        state.selection = NSRange(location: text.length, length: 0)
        state.mode = state.hexSettings.dictationMode
        state.language = state.hexSettings.outputLanguage ?? "de"
        state.$isDictationBoxPresented.withLock { $0 = true }
        state.lastAction = "Restored dictation"
        return .run { _ in await MainActor.run { NotificationCenter.default.post(name: .presentDictationBox, object: nil) } }

      case .recordingStarted:
        state.replacementRange = state.selection.length > 0 ? state.selection : nil
        state.suggestion = nil
        return .none

      case let .dictationFinished(output, audioURL):
        state.audioURLs.append(audioURL)
        return applyDictation(&state, output: output)

      case let .textEdited(text, selection):
        state.text = text
        state.selection = selection
        state.suggestion = nil
        return saveDraft(state)

      case let .selectionChanged(selection):
        state.selection = selection
        guard selection.length > 0, selection.length <= 60 else { return .none }
        let words = BoxTextEditing.wordCount((state.text.string as NSString).substring(with: BoxTextEditing.clamp(selection, length: state.text.length)))
        guard (1...3).contains(words) else { return .none }
        return .send(.wordHovered(selection))

      case let .wordHovered(range):
        let clamped = BoxTextEditing.clamp(range, length: state.text.length)
        guard clamped.length > 0 else { return .none }
        let word = (state.text.string as NSString).substring(with: clamped)
        if state.suggestion?.range == clamped { return .none }
        let original = state.text.value.attribute(.localASRCorrectionOriginal, at: clamped.location, effectiveRange: nil) as? String
        state.suggestion = SuggestionState(range: clamped, word: word, original: original)
        let context = LexiconContext(
          mode: state.mode,
          language: state.language,
          profile: state.hexSettings.asrProfile,
          activePacks: state.hexSettings.activeLexiconPacks,
          autoReplacePackTermsInLiteral: state.hexSettings.autoReplaceTermsLiteral
        )
        return .run { [lexicon] send in
          let suggestions = await lexicon.suggestions(word, context)
          await send(.suggestionsLoaded(suggestions, for: clamped))
        }
        .cancellable(id: CancelID.suggestions, cancelInFlight: true)

      case let .suggestionsLoaded(suggestions, range):
        guard state.suggestion?.range == range else { return .none }
        state.suggestion?.suggestions = suggestions
        state.suggestion?.isLoading = false
        return .none

      case let .applySuggestion(term):
        guard let suggestion = state.suggestion else { return .none }
        replace(&state, range: suggestion.range, with: term, learnFrom: suggestion.original ?? suggestion.word)
        state.lastAction = "“\(suggestion.word)” → “\(term)”"
        return saveDraft(state)

      case .revertCorrection:
        guard let suggestion = state.suggestion, let original = suggestion.original else { return .none }
        replace(&state, range: suggestion.range, with: original, learnFrom: nil)
        state.lastAction = "Replacement undone"
        return saveDraft(state)

      case .prepareRedictation:
        guard let suggestion = state.suggestion else { return .none }
        state.selection = suggestion.range
        state.revision += 1
        state.suggestion = nil
        state.lastAction = "Re-dictate selection: press the dictation key"
        return .none

      case .spellSelection:
        if let suggestion = state.suggestion {
          state.selection = suggestion.range
          state.revision += 1
        }
        state.suggestion = nil
        state.spellingMode = true
        state.lastAction = "Spelling: press the dictation key"
        return .none

      case .addHoveredWordToLexicon:
        guard let suggestion = state.suggestion else { return .none }
        let entry = LexiconEntry(
          term: suggestion.word,
          lang: state.language.hasPrefix("en") ? "en" : "de",
          category: "user",
          aliases: suggestion.original.map { [$0] } ?? [],
          caseSensitive: true,
          autoReplace: true
        )
        state.suggestion = nil
        state.lastAction = "“\(suggestion.word)” added to vocabulary"
        return .run { [lexicon] _ in try? await lexicon.addUserEntries([entry]) }

      case .dismissSuggestions:
        state.suggestion = nil
        return .cancel(id: CancelID.suggestions)

      case .toggleBold:
        return edit(&state, "Bold") { BoxTextEditing.toggleTrait(.boldFontMask, in: $0, range: $1) }
      case .toggleItalic:
        return edit(&state, "Italic") { BoxTextEditing.toggleTrait(.italicFontMask, in: $0, range: $1) }
      case .toggleHeading:
        let base = state.baseFont
        return edit(&state, "Heading") { BoxTextEditing.toggleHeading(in: $0, range: $1, baseFont: base) }
      case .toggleBullets:
        let base = state.baseFont
        return edit(&state, "Bullets") { BoxTextEditing.toggleBullets(in: $0, range: $1, baseFont: base) }
      case .quoteSelection:
        let language = state.language
        return edit(&state, "Quotes") { BoxTextEditing.quote(in: $0, range: $1, language: language) }
      case .cycleCase:
        return edit(&state, "Case") { BoxTextEditing.cycleCase(in: $0, range: $1) }

      case .toggleSpellingMode:
        state.spellingMode.toggle()
        state.lastAction = state.spellingMode ? "Spelling: press the dictation key" : "Spelling off"
        return .none

      case let .setFont(name):
        state.$hexSettings.withLock { $0.boxFontName = name }
        state.text = BoxText(BoxTextEditing.applyBaseFont(state.baseFont, to: state.text.value))
        state.revision += 1
        return saveDraft(state)

      case let .setFontSize(size):
        state.$hexSettings.withLock { $0.boxFontSize = min(max(size, 11), 28) }
        state.text = BoxText(BoxTextEditing.applyBaseFont(state.baseFont, to: state.text.value))
        state.revision += 1
        return saveDraft(state)

      case let .setFormat(format):
        state.$hexSettings.withLock { $0.boxOutputFormat = format }
        return .none

      case let .setLanguage(language):
        state.language = language ?? state.hexSettings.outputLanguage ?? "de"
        return .none

      case .confirmTapped:
        return confirm(&state)

      case .discardTapped:
        if state.wordCount > 20 {
          state.isConfirmingDiscard = true
          return .none
        }
        return .send(.discardConfirmed)

      case .discardConfirmed:
        state.isConfirmingDiscard = false
        let discardedWords = state.wordCount
        boxLogger.notice("Dictation box discarded (\(discardedWords) words)")
        return finish(&state)

      case .learnConfirmed:
        let entries = state.learnCandidates.filter(\.isSelected).map { candidate in
          LexiconEntry(
            term: candidate.replacement,
            lang: state.language.hasPrefix("en") ? "en" : "de",
            category: "user",
            aliases: candidate.original.isEmpty ? [] : [candidate.original],
            caseSensitive: true,
            autoReplace: true
          )
        }
        return .merge(
          .run { [lexicon] _ in try? await lexicon.addUserEntries(entries) },
          .send(.close)
        )

      case .learnSkipped:
        return .send(.close)

      case .close:
        return finish(&state)
      }
    }
  }

  // MARK: - Dictation results

  private func applyDictation(_ state: inout State, output: DictationSessionOutput) -> Effect<Action> {
    var effects: [Effect<Action>] = []
    // Edit commands that refer to earlier dictations in the box.
    for edit in output.document.unappliedEdits {
      switch edit {
      case .deleteLastUtterance, .undo:
        if let previous = state.snapshots.popLast() {
          state.text = previous
          state.lastAction = edit == .undo ? "Undo" : "Deleted last dictation"
        }
      case .deleteLastSentence:
        state.text = BoxText(BoxTextEditing.deleteLastSentence(state.text.value))
        state.lastAction = "Deleted last sentence"
      case .deleteLastWord:
        state.text = BoxText(BoxTextEditing.deleteLastWord(state.text.value))
        state.lastAction = "Deleted last word"
      case .clearAll:
        state.snapshots.append(state.text)
        state.text = BoxText()
        state.lastAction = "Cleared everything"
      }
      state.selection = NSRange(location: state.text.length, length: 0)
      state.revision += 1
    }

    let spell = output.document.boxCommands.contains(.spell)
    let transfer = output.document.boxCommands.contains(.transfer)
    let target = state.replacementRange ?? state.selection
    state.replacementRange = nil

    if state.spellingMode {
      let spelled = SpellingInterpreter.interpret(output.rawText)
      state.spellingMode = false
      if !spelled.isEmpty {
        let original = (state.text.string as NSString).substring(with: BoxTextEditing.clamp(target, length: state.text.length))
        insert(&state, NSAttributedString(string: spelled, attributes: BoxTextStyle.attributes(font: state.baseFont)), at: target)
        state.learnCandidates.append(LearnCandidate(original: original, replacement: spelled))
        state.lastAction = "Spelled: “\(spelled)”"
      }
    } else if !output.markdown.isEmpty, !output.document.isEmpty {
      let converted = BoxTextConverter.attributed(fromMarkdown: output.markdown, baseFont: state.baseFont, corrections: output.document.corrections)
      let attributed = NSMutableAttributedString(attributedString: converted)
      BoxTextConverter.markUncertain(output.uncertainWords, in: attributed)
      let replacedText = target.length > 0
        ? (state.text.string as NSString).substring(with: BoxTextEditing.clamp(target, length: state.text.length))
        : ""
      insert(&state, attributed, at: target)
      if !replacedText.isEmpty, (1...3).contains(BoxTextEditing.wordCount(replacedText)),
         (1...3).contains(BoxTextEditing.wordCount(output.text)), replacedText != output.text {
        state.learnCandidates.append(LearnCandidate(original: replacedText, replacement: output.text))
      }
      if state.lastAction.isEmpty || output.document.unappliedEdits.isEmpty {
        state.lastAction = Self.describe(output)
      }
    }

    if spell {
      state.spellingMode = true
      state.lastAction = "Spelling: press the dictation key"
    }
    effects.append(saveDraft(state))
    if transfer { effects.append(.send(.confirmTapped)) }
    return .merge(effects)
  }

  private func insert(_ state: inout State, _ attributed: NSAttributedString, at range: NSRange) {
    state.snapshots.append(state.text)
    if state.snapshots.count > 50 { state.snapshots.removeFirst() }
    let (text, inserted) = BoxTextEditing.insert(attributed, into: state.text.value, replacing: range)
    state.text = BoxText(text)
    state.selection = NSRange(location: inserted.location + inserted.length, length: 0)
    state.revision += 1
  }

  private func replace(_ state: inout State, range: NSRange, with term: String, learnFrom original: String?) {
    let clamped = BoxTextEditing.clamp(range, length: state.text.length)
    let text = NSMutableAttributedString(attributedString: state.text.value)
    var attributes = clamped.length > 0 ? text.attributes(at: clamped.location, effectiveRange: nil) : BoxTextStyle.attributes(font: state.baseFont)
    attributes[.localASRCorrectionOriginal] = nil
    attributes[.localASRUncertain] = nil
    attributes[.underlineStyle] = nil
    attributes[.underlineColor] = nil
    text.replaceCharacters(in: clamped, with: NSAttributedString(string: term, attributes: attributes))
    state.snapshots.append(state.text)
    state.text = BoxText(text)
    state.selection = NSRange(location: clamped.location + (term as NSString).length, length: 0)
    state.revision += 1
    state.suggestion = nil
    if let original, original != term {
      state.learnCandidates.removeAll { $0.original == original }
      state.learnCandidates.append(LearnCandidate(original: original, replacement: term))
    }
  }

  private func edit(_ state: inout State, _ label: String, _ transform: (NSAttributedString, NSRange) -> NSAttributedString) -> Effect<Action> {
    let range = state.selection.length > 0
      ? state.selection
      : (BoxTextEditing.wordRange(at: max(state.selection.location - 1, 0), in: state.text.string) ?? state.selection)
    state.snapshots.append(state.text)
    state.text = BoxText(transform(state.text.value, range))
    state.revision += 1
    state.lastAction = label
    return saveDraft(state)
  }

  static func describe(_ output: DictationSessionOutput) -> String {
    let tokens = output.document.tokens
    if tokens.last == .paragraphBreak { return "¶ New paragraph" }
    if tokens.last == .lineBreak { return "↵ New line" }
    if let mark = tokens.last(where: { if case .mark = $0 { return true } else { return false } }), case let .mark(value) = mark {
      return "Punctuation “\(value.glyph(language: output.language))”"
    }
    if !output.document.corrections.isEmpty {
      return "\(output.document.corrections.count) term correction(s)"
    }
    return "Dictation added"
  }

  // MARK: - Confirm / discard

  private func confirm(_ state: inout State) -> Effect<Action> {
    let text = state.text.value
    guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return finish(&state) }
    let payload: RichPastePayload
    switch state.hexSettings.boxOutputFormat {
    case .richText:
      payload = RichPastePayload(plain: BoxTextConverter.plainText(from: text), rtf: BoxTextConverter.rtf(from: text), targetBundleID: state.targetBundleID)
    case .markdown:
      payload = RichPastePayload(plain: BoxTextConverter.markdown(from: text), rtf: nil, targetBundleID: state.targetBundleID)
    case .plainText:
      payload = RichPastePayload(plain: BoxTextConverter.plainText(from: text), rtf: nil, targetBundleID: state.targetBundleID)
    }
    let confirmedWords = state.wordCount
    boxLogger.notice("Dictation box confirmed (\(confirmedWords) words)")
    let audioURLs = state.audioURLs
    state.audioURLs = []
    let hasLearnCandidates = !state.learnCandidates.isEmpty
    if hasLearnCandidates {
      state.phase = .learning
    }
    let saveHistory = state.hexSettings.saveTranscriptionHistory
    let maxHistoryEntries = state.hexSettings.maxHistoryEntries
    let history = state.$transcriptionHistory
    let historyText = BoxTextConverter.plainText(from: text)
    let target = (state.targetBundleID, state.targetAppName)
    return .merge(
      .run { [pasteboard, transcriptPersistence] send in
        await MainActor.run { NotificationCenter.default.post(name: .dictationBoxWillPaste, object: nil) }
        await pasteboard.pasteRich(payload)
        // Keep the text in the history (the user's fallback when insertion fails).
        if saveHistory, let firstAudio = audioURLs.first {
          let duration = audioURLs.reduce(0.0) { total, url in
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return total }
            return total + Double(file.length) / file.processingFormat.sampleRate
          }
          if let transcript = try? await transcriptPersistence.save(historyText, firstAudio, duration, target.0, target.1) {
            history.withLock { history in
              history.history.insert(transcript, at: 0)
              if let maxHistoryEntries, maxHistoryEntries > 0 {
                while history.history.count > maxHistoryEntries { _ = history.history.popLast() }
              }
            }
          }
        }
        for url in audioURLs { FileManager.default.removeItemIfExists(at: url) }
        DictationBoxDraftStore.remove()
        if !hasLearnCandidates { await send(.close) }
      },
      .cancel(id: CancelID.draft)
    )
  }

  private func finish(_ state: inout State) -> Effect<Action> {
    let audioURLs = state.audioURLs
    state.isPresented = false
    state.phase = .editing
    state.text = BoxText()
    state.revision += 1
    state.snapshots = []
    state.learnCandidates = []
    state.suggestion = nil
    state.spellingMode = false
    state.audioURLs = []
    state.$isDictationBoxPresented.withLock { $0 = false }
    return .merge(
      .cancel(id: CancelID.draft),
      .cancel(id: CancelID.suggestions),
      .run { _ in
        for url in audioURLs { FileManager.default.removeItemIfExists(at: url) }
        DictationBoxDraftStore.remove()
        await MainActor.run { NotificationCenter.default.post(name: .dismissDictationBox, object: nil) }
      }
    )
  }

  /// Crash protection: the box text is written (debounced) to the recovery folder.
  private func saveDraft(_ state: State) -> Effect<Action> {
    let text = state.text
    return .run { _ in
      try await Task.sleep(for: .milliseconds(800))
      DictationBoxDraftStore.save(text)
    }
    .cancellable(id: CancelID.draft, cancelInFlight: true)
  }
}

extension Notification.Name {
  static let presentDictationBox = Notification.Name("LocalASR.presentDictationBox")
  static let dismissDictationBox = Notification.Name("LocalASR.dismissDictationBox")
  static let dictationBoxWillPaste = Notification.Name("LocalASR.dictationBoxWillPaste")
}

/// RTF draft of the open box in `Application Support/.../recovery/box-draft.rtf`.
enum DictationBoxDraftStore {
  static var url: URL? {
    guard !isTesting else { return nil }
    return try? URL.hexApplicationSupport.appendingPathComponent("recovery", isDirectory: true).appendingPathComponent("box-draft.rtf")
  }

  static func save(_ text: BoxText) {
    guard let url else { return }
    if text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      remove()
      return
    }
    guard let data = try? text.value.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? data.write(to: url, options: [.atomic, .completeFileProtection])
  }

  static func load() -> BoxText? {
    guard let url, let data = try? Data(contentsOf: url),
          let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
          !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return BoxText(text)
  }

  static func remove() {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
  }
}
