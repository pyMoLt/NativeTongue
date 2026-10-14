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

  /// AI post-processing in the box: the ✨ button becomes ⇄ (diff) after a run.
  enum AIPhase: Equatable {
    case idle
    /// Running with this style id.
    case running(String)
    case done
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
    /// Counters of earlier manual corrections (plan B8), loaded when the box opens.
    var learnedCorrections: [LearnedCorrection] = []
    var suggestion: SuggestionState?
    var isConfirmingDiscard = false
    var aiPhase: AIPhase = .idle
    /// Box text before the last AI run (diff "before" side).
    var aiOriginalText = ""
    var aiResultText = ""
    var aiIssues: [PolishGuardIssue] = []
    var isShowingDiff = false
    /// Command Mode (C3): the box holds a selection from another app; a
    /// spoken or typed instruction (or a style) rewrites it and ✓ replaces
    /// the selection.
    var isCommandMode = false
    var instruction = ""
    @Shared(.hexSettings) var hexSettings: HexSettings
    /// Settings of the target app's profile (C2).
    var targetSettings: HexSettings { hexSettings.effective(forApp: targetBundleID) }
    @Shared(.isDictationBoxPresented) var isDictationBoxPresented: Bool = false
    @Shared(.dictationBoxPlainText) var plainTextForCommands: String = ""
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.lastTranscript) var lastTranscript: LastTranscript? = nil

    var baseFont: NSFont {
      BoxTextStyle.baseFont(name: hexSettings.boxFontName, size: hexSettings.boxFontSize)
    }

    var wordCount: Int { BoxTextEditing.wordCount(text.string) }

    /// The ✨ button is offered when AI post-processing and the box button are on.
    var offersAI: Bool {
      hexSettings.postProcessing.enabled && hexSettings.postProcessing.boxButtonEnabled
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case present(targetBundleID: String?, targetAppName: String?, mode: DictationMode)
    /// Opens the box in Command Mode with the selected text of the target app.
    case presentCommand(targetBundleID: String?, targetAppName: String?, selection: String)
    /// Runs the typed or spoken instruction on the box text.
    case commandRun
    case restoreDraft(BoxText)
    case recordingStarted
    case dictationFinished(DictationSessionOutput, URL)
    /// Text streamed live into the box (Literal + streaming in the box).
    case streamedText(String)
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
    // AI post-processing
    /// Runs the AI with this style id.
    case aiTapped(String)
    case aiPartial(String)
    case aiFinished(PolishOutcome)
    case aiCancelTapped
    case diffToggled
    case aiRevertTapped
    // Finish
    case confirmTapped
    case discardTapped
    case discardConfirmed
    case learnConfirmed
    case learnSkipped
    case learnedLoaded([LearnedCorrection])
    case close
  }

  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.lexicon) var lexicon
  @Dependency(\.llm) var llm

  private enum CancelID { case suggestions, draft, ai }

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
        return .merge(
          .run { _ in await MainActor.run { NotificationCenter.default.post(name: .presentDictationBox, object: nil) } },
          loadLearnedCorrections()
        )

      case let .presentCommand(targetBundleID, targetAppName, selection):
        guard !state.isPresented else { return .none }
        state = State()
        state.isPresented = true
        state.isCommandMode = true
        state.targetBundleID = targetBundleID
        state.targetAppName = targetAppName
        state.mode = .normal
        state.language = state.hexSettings.outputLanguage ?? "de"
        state.text = BoxText(NSAttributedString(string: selection))
        state.revision += 1
        state.$isDictationBoxPresented.withLock { $0 = true }
        state.lastAction = "Say or type what to do with the selection"
        return .run { _ in await MainActor.run { NotificationCenter.default.post(name: .presentDictationBox, object: nil) } }

      case .commandRun:
        let instruction = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.isCommandMode, !instruction.isEmpty else { return .none }
        return startAI(&state, style: AIStyle.oneOff(instruction: instruction))

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
        return .merge(
          .run { _ in await MainActor.run { NotificationCenter.default.post(name: .presentDictationBox, object: nil) } },
          loadLearnedCorrections()
        )

      case .recordingStarted:
        state.replacementRange = state.selection.length > 0 ? state.selection : nil
        state.suggestion = nil
        return .none

      case let .dictationFinished(output, audioURL) where state.isCommandMode && state.aiPhase != .done:
        // Command Mode: the dictation is the instruction, not more text.
        try? FileManager.default.removeItem(at: audioURL)
        state.instruction = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .send(.commandRun)

      case let .dictationFinished(output, audioURL):
        state.audioURLs.append(audioURL)
        // A dictation during a running AI pass: the original text comes back
        // first, then the dictation is added (audit M5).
        let abortAI = abortRunningAI(&state)
        resetAI(&state)
        return .merge(abortAI, applyDictation(&state, output: output))

      case let .streamedText(text):
        guard state.isPresented, state.phase == .editing else { return .none }
        let abortAI = abortRunningAI(&state)
        return .merge(abortAI, appendStreamed(&state, text: text))

      case let .textEdited(text, selection):
        // Editor callbacks also arrive while the AI streams text in.
        if case .running = state.aiPhase { return .none }
        if text.string != state.text.string, state.aiPhase == .done { resetAI(&state) }
        if let candidate = Self.manualCorrection(from: state.text.string, to: text.string, replacing: state.selection) {
          state.learnCandidates.removeAll { $0.original == candidate.original }
          state.learnCandidates.append(candidate)
        }
        state.text = text
        state.selection = selection
        state.suggestion = nil
        return saveDraft(state)

      case let .aiTapped(styleID):
        return startAI(&state, style: state.targetSettings.postProcessing.style(id: styleID))

      case let .aiPartial(partial):
        guard case .running = state.aiPhase else { return .none }
        state.text = BoxText(NSAttributedString(string: partial, attributes: BoxTextStyle.attributes(font: state.baseFont)))
        state.revision += 1
        return .none

      case let .aiFinished(outcome):
        return finishAI(&state, outcome: outcome)

      case .aiCancelTapped:
        guard case .running = state.aiPhase else { return .none }
        let effect = abortRunningAI(&state)
        state.lastAction = "AI cancelled"
        return effect

      case .diffToggled:
        guard state.aiPhase == .done else { return .none }
        state.isShowingDiff.toggle()
        return .none

      case .aiRevertTapped:
        guard state.aiPhase == .done else { return .none }
        if let previous = state.snapshots.popLast() { state.text = previous }
        state.revision += 1
        resetAI(&state)
        state.lastAction = "Original restored"
        return saveDraft(state)

      case let .selectionChanged(selection):
        state.selection = selection
        guard selection.length > 0, selection.length <= 60 else { return .none }
        let words = BoxTextEditing.wordCount((state.text.string as NSString).substring(with: BoxTextEditing.clamp(selection, length: state.text.length)))
        guard (1...5).contains(words) else { return .none }
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
          profile: state.targetSettings.asrProfile,
          activePacks: state.targetSettings.activeLexiconPacks,
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
        let selected = state.learnCandidates.filter(\.isSelected)
        let entries = selected.map { candidate in
          LexiconEntry(
            term: candidate.replacement,
            lang: state.language.hasPrefix("en") ? "en" : "de",
            category: "user",
            aliases: candidate.original.isEmpty ? [] : [candidate.original],
            caseSensitive: true,
            autoReplace: true
          )
        }
        // Accepted pairs become aliases; unticked ones are not offered again.
        let accepted = selected.map { LearnedCorrection(original: $0.original, replacement: $0.replacement) }
        let declined = state.learnCandidates.filter { !$0.isSelected }.map { LearnedCorrection(original: $0.original, replacement: $0.replacement) }
        return .merge(
          .run { [lexicon] _ in
            try? await lexicon.addUserEntries(entries)
            await lexicon.resolveCorrections(accepted, declined)
          },
          .send(.close)
        )

      case let .learnedLoaded(counters):
        state.learnedCorrections = counters
        return .none

      case .learnSkipped:
        return .send(.close)

      case .close:
        return finish(&state)
      }
    }
    Reduce { state, _ in
      // Mirror the text for the command recogniser of the next dictation.
      let plain = state.isPresented ? state.text.string : ""
      if state.plainTextForCommands != plain { state.$plainTextForCommands.withLock { $0 = plain } }
      return .none
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
      case let .deleteLastWords(count):
        var text = state.text.value
        for _ in 0..<count { text = BoxTextEditing.deleteLastWord(text) }
        state.text = BoxText(text)
        state.lastAction = "Deleted last \(count) words"
      case let .replace(old, new):
        if let replaced = BoxTextEditing.replaceLast(old, with: new, in: state.text.value) {
          state.snapshots.append(state.text)
          state.text = BoxText(replaced)
          state.lastAction = "Replaced “\(old)” with “\(new)”"
        } else {
          state.lastAction = "⚠︎ “\(old)” not found"
        }
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
      if !replacedText.isEmpty, (1...5).contains(BoxTextEditing.wordCount(replacedText)),
         (1...5).contains(BoxTextEditing.wordCount(output.text)), replacedText != output.text {
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
    if !transfer {
      effects.append(.run { _ in
        await MainActor.run { NotificationCenter.default.post(name: .focusDictationBox, object: nil) }
      })
    }
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

  /// A deliberate selection replacement can become an optional lexicon alias.
  /// Ignore free typing and punctuation edits, which do not identify a reliable
  /// ASR mistake. The user still chooses whether to save the suggestion.
  static func manualCorrection(from old: String, to new: String, replacing selection: NSRange) -> LearnCandidate? {
    let before = old as NSString
    let after = new as NSString
    guard selection.length > 0, selection.location >= 0,
          NSMaxRange(selection) <= before.length else { return nil }
    let insertedLength = after.length - before.length + selection.length
    guard insertedLength > 0, selection.location + insertedLength <= after.length else { return nil }
    let prefix = before.substring(to: selection.location)
    let suffix = before.substring(from: NSMaxRange(selection))
    guard new.hasPrefix(prefix), new.hasSuffix(suffix) else { return nil }
    let original = before.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
    let replacement = after.substring(with: NSRange(location: selection.location, length: insertedLength))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard original != replacement,
          (1...5).contains(BoxTextEditing.wordCount(original)),
          (1...5).contains(BoxTextEditing.wordCount(replacement)),
          original.contains(where: \.isLetter), replacement.contains(where: \.isLetter) else { return nil }
    return LearnCandidate(original: original, replacement: replacement)
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
    // Every manual correction is counted; „Always replace?“ only from the
    // threshold on (plan B8). Spelled new words without an original are offered at once.
    let corrections = state.learnCandidates.filter { !$0.original.isEmpty }
      .map { LearnedCorrection(original: $0.original, replacement: $0.replacement) }
    let counted = LearnedCorrection.counting(corrections, into: state.learnedCorrections)
    let offered = Set(LearnedCorrection.offers(counted, threshold: state.hexSettings.textProcessing.learnCorrectionThreshold).map(\.id))
    state.learnCandidates.removeAll { !$0.original.isEmpty && !offered.contains(LearnedCorrection(original: $0.original, replacement: $0.replacement).id) }
    state.learnedCorrections = counted
    let hasLearnCandidates = !state.learnCandidates.isEmpty
    if hasLearnCandidates {
      state.phase = .learning
    }
    let saveHistory = state.hexSettings.saveTranscriptionHistory
    let maxHistoryEntries = state.hexSettings.maxHistoryEntries
    let history = state.$transcriptionHistory
    let historyText = BoxTextConverter.plainText(from: text)
    state.$lastTranscript.withLock { $0 = LastTranscript(text: historyText, date: Date(), appName: state.targetAppName) }
    let target = (state.targetBundleID, state.targetAppName)
    return .merge(
      .run { [pasteboard, transcriptPersistence, lexicon] send in
        await MainActor.run { NotificationCenter.default.post(name: .dictationBoxWillPaste, object: nil) }
        await pasteboard.pasteRich(payload)
        // Keep the text in the history (the user's fallback when insertion fails).
        if saveHistory, let firstAudio = audioURLs.first {
          let duration = audioURLs.reduce(0.0) { total, url in
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return total }
            return total + Double(file.length) / file.processingFormat.sampleRate
          }
          if let transcript = try? await transcriptPersistence.save(historyText, firstAudio, duration, target.0, target.1) {
            let removed = history.withLock { $0.insertNewest(transcript, limit: maxHistoryEntries) }
            // Trimmed entries take their recordings along (audit M6).
            for entry in removed { try? await transcriptPersistence.deleteAudio(entry) }
          }
        }
        for url in audioURLs { FileManager.default.removeItemIfExists(at: url) }
        DictationBoxDraftStore.remove()
        if !corrections.isEmpty { _ = await lexicon.recordCorrections(corrections) }
        if !hasLearnCandidates { await send(.close) }
      },
      .cancel(id: CancelID.draft)
    )
  }

  // MARK: - Streaming into the box

  /// Streamed pieces arrive already formatted by the streaming processor in
  /// Literal punctuation mode (spoken punctuation, numbers); only spacing and
  /// sentence-start capitals are fitted to the box text.
  private func appendStreamed(_ state: inout State, text: String) -> Effect<Action> {
    var rendered = text
    guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
    let target = BoxTextEditing.clamp(state.replacementRange ?? state.selection, length: state.text.length)
    state.replacementRange = nil
    let before = (state.text.string as NSString).substring(to: target.location)
    rendered = String(StreamingTextJoiner.join(rendered, after: before, adapt: true).drop { $0 == " " })
    if target.location == 0, state.text.length == 0 { state.snapshots.append(state.text) }
    let attributed = BoxTextConverter.attributed(fromMarkdown: rendered, baseFont: state.baseFont)
    let (newText, inserted) = BoxTextEditing.insert(attributed, into: state.text.value, replacing: target)
    state.text = BoxText(newText)
    state.selection = NSRange(location: inserted.location + inserted.length, length: 0)
    state.revision += 1
    resetAI(&state)
    return saveDraft(state)
  }

  private func loadLearnedCorrections() -> Effect<Action> {
    .run { [lexicon] send in await send(.learnedLoaded(await lexicon.userLexicon().learnedCorrections)) }
  }

  // MARK: - AI post-processing

  /// Stops a running AI pass and restores the text from before it.
  private func abortRunningAI(_ state: inout State) -> Effect<Action> {
    guard case .running = state.aiPhase else { return .none }
    if let previous = state.snapshots.popLast() { state.text = previous }
    state.revision += 1
    resetAI(&state)
    return .cancel(id: CancelID.ai)
  }

  private func resetAI(_ state: inout State) {
    state.aiPhase = .idle
    state.aiIssues = []
    state.isShowingDiff = false
  }

  private func startAI(_ state: inout State, style: AIStyle) -> Effect<Action> {
    let settings = state.targetSettings.postProcessing
    guard state.offersAI || state.isCommandMode, state.aiPhase != .running(style.id) else { return .none }
    let markdown = BoxTextConverter.markdown(from: state.text.value).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !markdown.isEmpty else { return .none }
    let modelID = settings.boxModel
    guard let model = LLMModelCatalog.descriptor(id: modelID, settings: settings), llm.isInstalled(model) else {
      state.lastAction = modelID.isEmpty
        ? "⚠︎ No AI model selected — choose one under AI Post-Processing"
        : "⚠︎ The selected AI model is not installed — install it under AI Post-Processing"
      return .none
    }
    state.snapshots.append(state.text)
    state.aiOriginalText = markdown
    state.aiPhase = .running(style.id)
    state.isShowingDiff = false
    state.suggestion = nil
    state.lastAction = "\(style.name) …"
    var prepared = PolishRequest(text: markdown, style: style, modelID: modelID, settings: settings)
    if settings.context.use != .off {
      // The box text is the whole text; only the app is useful context.
      var appOnly = settings.context
      appOnly.use = .appOnly
      prepared.context = ContextAnalyzer.prompt(ContextHints(), context: AIContext(appName: state.targetAppName), settings: appOnly)
    }
    let request = prepared
    return .run { [llm, lexicon] send in
      var request = request
      let terms = await lexicon.userLexicon().entries.map(\.term)
      request.protectedTerms = terms.filter { request.text.localizedCaseInsensitiveContains($0) }
      // Partial results arrive in order and before the final one (audit L2).
      let (partials, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
      async let forwarded: Void = {
        for await partial in partials { await send(.aiPartial(partial)) }
      }()
      let outcome = await llm.polish(request, true) { partial in continuation.yield(partial) }
      continuation.finish()
      await forwarded
      await send(.aiFinished(outcome))
    }
    .cancellable(id: CancelID.ai, cancelInFlight: true)
  }

  private func finishAI(_ state: inout State, outcome: PolishOutcome) -> Effect<Action> {
    guard case .running = state.aiPhase else { return .none }
    guard !outcome.failed, let aiText = outcome.aiText else {
      if let previous = state.snapshots.popLast() { state.text = previous }
      state.revision += 1
      resetAI(&state)
      state.lastAction = "⚠︎ AI post-processing failed — text unchanged"
      return .none
    }
    let attributed = NSMutableAttributedString(attributedString: BoxTextConverter.attributed(fromMarkdown: aiText, baseFont: state.baseFont))
    let marked = outcome.issues.map(\.detail).filter { !$0.isEmpty && aiText.contains($0) }
    BoxTextConverter.markUncertain(marked, in: attributed)
    state.text = BoxText(attributed)
    state.selection = NSRange(location: attributed.length, length: 0)
    state.revision += 1
    state.aiResultText = aiText
    state.aiIssues = outcome.issues
    state.aiPhase = .done
    state.isShowingDiff = state.hexSettings.postProcessing.boxShowsDiffAutomatically
    state.lastAction = outcome.issues.first.map { "⚠︎ \($0.explanation)" } ?? "AI done — ⇄ shows the changes"
    return saveDraft(state)
  }

  private func finish(_ state: inout State) -> Effect<Action> {
    let audioURLs = state.audioURLs
    resetAI(&state)
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
      .cancel(id: CancelID.ai),
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
  static let focusDictationBox = Notification.Name("LocalASR.focusDictationBox")
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
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
