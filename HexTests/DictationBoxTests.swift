import AppKit
import ComposableArchitecture
import HexCore
import XCTest

@testable import Hex

final class BoxTextTests: XCTestCase {
  private let font = NSFont.systemFont(ofSize: 15)

  func testMarkdownRoundTrip() {
    let markdown = "# Befund\n- Erster Punkt\nDas ist **wichtig** und *kursiv*."
    let attributed = BoxTextConverter.attributed(fromMarkdown: markdown, baseFont: font)
    XCTAssertEqual(attributed.string, "Befund\n• Erster Punkt\nDas ist wichtig und kursiv.")
    XCTAssertEqual(BoxTextConverter.markdown(from: attributed), markdown)
  }

  func testRTFExportDropsBoxMarkers() throws {
    let attributed = BoxTextConverter.attributed(
      fromMarkdown: "Wir nutzen Qwen",
      baseFont: font,
      corrections: [LexiconCorrection(original: "Gwen", replacement: "Qwen", rule: .alias)]
    )
    let range = (attributed.string as NSString).range(of: "Qwen")
    XCTAssertEqual(attributed.attribute(.localASRCorrectionOriginal, at: range.location, effectiveRange: nil) as? String, "Gwen")
    let export = BoxTextConverter.exportCopy(attributed)
    XCTAssertNil(export.attribute(.localASRCorrectionOriginal, at: range.location, effectiveRange: nil))
    let rtf = try XCTUnwrap(BoxTextConverter.rtf(from: attributed))
    let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    XCTAssertEqual(decoded.string.trimmingCharacters(in: .newlines), "Wir nutzen Qwen")
  }

  func testInsertSpacing() {
    let base = NSAttributedString(string: "Hallo")
    let (spaced, range) = BoxTextEditing.insert(NSAttributedString(string: "Welt"), into: base, replacing: NSRange(location: 5, length: 0))
    XCTAssertEqual(spaced.string, "Hallo Welt")
    XCTAssertEqual(range, NSRange(location: 5, length: 5))
    let (punctuated, _) = BoxTextEditing.insert(NSAttributedString(string: "."), into: base, replacing: NSRange(location: 5, length: 0))
    XCTAssertEqual(punctuated.string, "Hallo.")
    let (middle, _) = BoxTextEditing.insert(NSAttributedString(string: "schöne"), into: NSAttributedString(string: "Hallo Welt"), replacing: NSRange(location: 6, length: 0))
    XCTAssertEqual(middle.string, "Hallo schöne Welt")
  }

  func testUncertainWordsGetOrangeMarkerButNotInExport() {
    let text = NSMutableAttributedString(string: "Die Iunum und das Duodenum", attributes: [.font: font])
    BoxTextConverter.markUncertain(["Iunum", "und"], in: text)
    let range = (text.string as NSString).range(of: "Iunum")
    XCTAssertEqual(text.attribute(.localASRUncertain, at: range.location, effectiveRange: nil) as? Bool, true)
    // "und" inside "Duodenum"? no – whole words only; the standalone "und" is marked.
    let inside = (text.string as NSString).range(of: "Duodenum")
    XCTAssertNil(text.attribute(.localASRUncertain, at: inside.location + 2, effectiveRange: nil))
    XCTAssertNil(BoxTextConverter.exportCopy(text).attribute(.localASRUncertain, at: range.location, effectiveRange: nil))
  }

  func testFormattingHelpers() {
    let text = NSAttributedString(string: "eins zwei", attributes: [.font: font])
    let bold = BoxTextEditing.toggleTrait(.boldFontMask, in: text, range: NSRange(location: 0, length: 4))
    XCTAssertEqual(BoxTextConverter.markdown(from: bold), "**eins** zwei")
    let plain = BoxTextEditing.toggleTrait(.boldFontMask, in: bold, range: NSRange(location: 0, length: 4))
    XCTAssertEqual(BoxTextConverter.markdown(from: plain), "eins zwei")
    let bullets = BoxTextEditing.toggleBullets(in: NSAttributedString(string: "a\nb", attributes: [.font: font]), range: NSRange(location: 0, length: 3), baseFont: font)
    XCTAssertEqual(bullets.string, "• a\n• b")
    XCTAssertEqual(BoxTextEditing.cycleCase(in: text, range: NSRange(location: 0, length: 4)).string, "Eins zwei")
    XCTAssertEqual(BoxTextEditing.quote(in: text, range: NSRange(location: 5, length: 4), language: "de").string, "eins „zwei“")
    XCTAssertEqual(BoxTextEditing.deleteLastWord(NSAttributedString(string: "eins zwei drei.")).string, "eins zwei")
    XCTAssertEqual(BoxTextEditing.deleteLastSentence(NSAttributedString(string: "Satz eins. Satz zwei.")).string, "Satz eins.")
  }
}

@MainActor
final class DictationBoxFeatureTests: XCTestCase {
  private func output(_ text: String, mode: DictationMode = .literal, boxOpen: Bool = true, raw: String? = nil) -> DictationSessionOutput {
    let aligned = [AlignedUtterance(utterance: Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: 900, pauseAfterMs: 900), text: text)]
    let document = DictationSessionProcessor.makeDocument(from: aligned, options: .init(mode: mode, formatNumbers: false, boxOpen: boxOpen))
    return DictationSessionOutput(
      document: document,
      language: "de",
      text: document.render(.init(language: "de", mode: mode)),
      markdown: document.render(.init(language: "de", mode: mode, format: .markdown)),
      rawText: raw ?? text
    )
  }

  private func makeStore(
    pasted: LockIsolated<[RichPastePayload]> = .init([]),
    learned: LockIsolated<[LexiconEntry]> = .init([]),
    counted: [LearnedCorrection] = [],
    recorded: LockIsolated<[[LearnedCorrection]]> = .init([]),
    resolved: LockIsolated<[([LearnedCorrection], [LearnedCorrection])]> = .init([])
  ) -> TestStoreOf<DictationBoxFeature> {
    let store = TestStore(initialState: DictationBoxFeature.State(hexSettings: Shared(value: HexSettings()))) {
      DictationBoxFeature()
    } withDependencies: {
      $0.pasteboard.pasteRich = { payload in pasted.withValue { $0.append(payload) } }
      $0.lexicon.addUserEntries = { entries in learned.withValue { $0 += entries } }
      $0.lexicon.userLexicon = { UserLexicon(learnedCorrections: counted) }
      $0.lexicon.recordCorrections = { pairs in recorded.withValue { $0.append(pairs) }; return pairs }
      $0.lexicon.resolveCorrections = { accepted, declined in resolved.withValue { $0.append((accepted, declined)) } }
      $0.lexicon.suggestions = { _, _ in
        [Suggestion(term: "Rivaroxaban", score: 0.95, isUser: false, lang: "de", category: "drug")]
      }
    }
    store.exhaustivity = .off
    return store
  }

  private func tempAudio() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("box-\(UUID().uuidString).wav")
    try Data([0]).write(to: url)
    return url
  }

  func testCommandModeTurnsTheDictationIntoAnInstructionForTheSelection() async throws {
    var settings = HexSettings()
    settings.postProcessing.enabled = true
    settings.postProcessing.commandModeEnabled = true
    settings.postProcessing.boxModel = "qwen35-4b-4bit"
    // `presentCommand` starts from a fresh state that reads the shared settings.
    @Shared(.hexSettings) var shared: HexSettings
    $shared.withLock { $0 = settings }
    let seen = LockIsolated<[PolishRequest]>([])
    let store = TestStore(initialState: DictationBoxFeature.State()) {
      DictationBoxFeature()
    } withDependencies: {
      $0.lexicon.userLexicon = { UserLexicon() }
      $0.llm.isInstalled = { _ in true }
      $0.llm.polish = { request, keep, _ in
        seen.withValue { $0.append(request) }
        XCTAssertTrue(keep)
        return PolishOutcome(text: "- Eins\n- Zwei", original: request.text, aiText: "- Eins\n- Zwei", issues: [], failed: false)
      }
    }
    store.exhaustivity = .off
    await store.send(.presentCommand(targetBundleID: "com.apple.TextEdit", targetAppName: "TextEdit", selection: "eins und zwei"))
    XCTAssertTrue(store.state.isCommandMode)
    XCTAssertEqual(store.state.text.string, "eins und zwei")

    // A dictation is the instruction, not more text.
    let audio = try tempAudio()
    await store.send(.dictationFinished(output("als Liste", mode: .normal), audio))
    await store.receive(\.commandRun)
    await store.receive(\.aiFinished)
    XCTAssertEqual(store.state.instruction.lowercased(), "als liste")
    XCTAssertEqual(store.state.text.string.contains("Eins"), true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "the instruction recording is deleted at once")
    let request = try XCTUnwrap(seen.value.first)
    XCTAssertEqual(request.text, "eins und zwei")
    XCTAssertTrue(request.style.instruction.lowercased().contains("instruction: als liste"))
    XCTAssertEqual(request.style.strictness, .off)
    XCTAssertEqual(store.state.aiPhase, .done, "the comparison is offered before ✓ replaces the selection")
  }

  func testDictationsCollectAndConfirmPastesRichTextAndRemovesAudio() async throws {
    let pasted = LockIsolated<[RichPastePayload]>([])
    let store = makeStore(pasted: pasted)
    await store.send(.present(targetBundleID: "com.apple.TextEdit", targetAppName: "TextEdit", mode: .literal))
    XCTAssertTrue(store.state.isPresented)
    XCTAssertTrue(store.state.isDictationBoxPresented)
    let first = try tempAudio(), second = try tempAudio()
    await store.send(.dictationFinished(output("Befund unauffällig Punkt"), first))
    await store.send(.dictationFinished(output("Keine Auffälligkeiten Punkt"), second))
    XCTAssertEqual(store.state.text.string, "Befund unauffällig. Keine Auffälligkeiten.")
    await store.send(.confirmTapped)
    await store.receive(\.close)
    XCTAssertEqual(pasted.value.first?.plain, "Befund unauffällig. Keine Auffälligkeiten.")
    XCTAssertNotNil(pasted.value.first?.rtf)
    XCTAssertEqual(pasted.value.first?.targetBundleID, "com.apple.TextEdit")
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    XCTAssertFalse(store.state.isPresented)
    XCTAssertFalse(store.state.isDictationBoxPresented)
  }

  /// Plan B1: „ersetze X durch Y“ and „lösche die letzten N Wörter“ on box text.
  func testReplaceAndDeleteLastWordsInBox() async throws {
    let store = makeStore()
    await store.send(.present(targetBundleID: nil, targetAppName: nil, mode: .normal))
    await store.send(.dictationFinished(output("Termin am Montag um zehn Uhr", mode: .normal), try tempAudio()))
    var replace = DictationDocument()
    replace.apply(.replace("Montag", with: "Dienstag"))
    await store.send(.dictationFinished(DictationSessionOutput(document: replace, language: "de", text: ""), try tempAudio()))
    XCTAssertEqual(store.state.text.string, "Termin am Dienstag um zehn Uhr")
    var delete = DictationDocument()
    delete.apply(.deleteLastWords(2))
    await store.send(.dictationFinished(DictationSessionOutput(document: delete, language: "de", text: ""), try tempAudio()))
    XCTAssertEqual(store.state.text.string, "Termin am Dienstag um")
    XCTAssertEqual(store.state.plainTextForCommands, "Termin am Dienstag um")
  }

  /// B4: a selection at recording start is replaced by the next dictation only.
  func testRedictationReplacesSelectionAndOffersLexicon() async throws {
    let learned = LockIsolated<[LexiconEntry]>([])
    // Corrected once before: the second time NativeTongue asks (plan B8).
    let store = makeStore(learned: learned, counted: [LearnedCorrection(original: "Gwen", replacement: "Qwen")])
    await store.send(.present(targetBundleID: nil, targetAppName: nil, mode: .literal))
    await store.receive(\.learnedLoaded)
    await store.send(.dictationFinished(output("wir nutzen Gwen heute"), try tempAudio()))
    let range = (store.state.text.string as NSString).range(of: "Gwen")
    await store.send(.selectionChanged(range))
    await store.send(.dismissSuggestions)
    await store.send(.recordingStarted)
    await store.send(.dictationFinished(output("Qwen"), try tempAudio()))
    XCTAssertEqual(store.state.text.string, "Wir nutzen Qwen heute")
    XCTAssertEqual(store.state.learnCandidates.map(\.original), ["Gwen"])
    await store.send(.confirmTapped)
    XCTAssertEqual(store.state.phase, .learning)
    await store.send(.learnConfirmed)
    await store.receive(\.close)
    XCTAssertEqual(learned.value.first?.term, "Qwen")
    XCTAssertEqual(learned.value.first?.aliases, ["Gwen"])
  }

  func testManualMultiwordReplacementOffersOptionalLexiconAlias() async throws {
    let store = makeStore(counted: [LearnedCorrection(original: "Vox Drill", replacement: "Voxtral")])
    await store.send(.present(targetBundleID: nil, targetAppName: nil, mode: .normal))
    await store.receive(\.learnedLoaded)
    await store.send(.dictationFinished(output("wir nutzen Vox Drill heute", mode: .normal), try tempAudio()))
    let range = (store.state.text.string as NSString).range(of: "Vox Drill")
    await store.send(.selectionChanged(range))
    let changed = store.state.text.string.replacingOccurrences(of: "Vox Drill", with: "Voxtral")
    await store.send(.textEdited(BoxText(NSAttributedString(string: changed)), selection: NSRange(location: range.location + 7, length: 0)))
    XCTAssertEqual(store.state.learnCandidates.first?.original, "Vox Drill")
    XCTAssertEqual(store.state.learnCandidates.first?.replacement, "Voxtral")
    await store.send(.confirmTapped)
    XCTAssertEqual(store.state.phase, .learning)
  }

  /// Plan B8: the first manual correction is only counted; from the threshold
  /// on NativeTongue asks, and unticked pairs are not offered again.
  func testCorrectionsAreCountedAndOfferedFromTheThreshold() async throws {
    let recorded = LockIsolated<[[LearnedCorrection]]>([])
    let resolved = LockIsolated<[([LearnedCorrection], [LearnedCorrection])]>([])
    let first = makeStore(recorded: recorded)
    await first.send(.present(targetBundleID: nil, targetAppName: nil, mode: .normal))
    await first.receive(\.learnedLoaded)
    await first.send(.dictationFinished(output("wir nutzen Vox Drill heute", mode: .normal), try tempAudio()))
    let range = (first.state.text.string as NSString).range(of: "Vox Drill")
    await first.send(.selectionChanged(range))
    let changed = first.state.text.string.replacingOccurrences(of: "Vox Drill", with: "Voxtral")
    await first.send(.textEdited(BoxText(NSAttributedString(string: changed)), selection: NSRange(location: range.location + 7, length: 0)))
    await first.send(.confirmTapped)
    XCTAssertNotEqual(first.state.phase, .learning, "first time: counted, not asked")
    await first.receive(\.close)
    XCTAssertEqual(recorded.value.first?.map(\.original), ["Vox Drill"])

    let second = makeStore(counted: [LearnedCorrection(original: "Vox Drill", replacement: "Voxtral")], resolved: resolved)
    await second.send(.present(targetBundleID: nil, targetAppName: nil, mode: .normal))
    await second.receive(\.learnedLoaded)
    await second.send(.dictationFinished(output("wir nutzen Vox Drill heute", mode: .normal), try tempAudio()))
    await second.send(.selectionChanged(range))
    await second.send(.textEdited(BoxText(NSAttributedString(string: changed)), selection: NSRange(location: range.location + 7, length: 0)))
    await second.send(.confirmTapped)
    XCTAssertEqual(second.state.phase, .learning)
    await second.send(.binding(.set(\.learnCandidates[0].isSelected, false)))
    await second.send(.learnConfirmed)
    await second.receive(\.close)
    await second.finish()
    XCTAssertEqual(resolved.value.first?.1.map(\.original), ["Vox Drill"], "unticked → not offered again")
  }

  /// B3: hovering a misrecognized word offers the lexicon term; click replaces.
  func testSuggestionReplacesWord() async throws {
    let store = makeStore()
    await store.send(.present(targetBundleID: nil, targetAppName: nil, mode: .literal))
    await store.send(.dictationFinished(output("Patient erhielt Ribaroxaban"), try tempAudio()))
    let range = (store.state.text.string as NSString).range(of: "Ribaroxaban")
    await store.send(.wordHovered(range))
    await store.receive(\.suggestionsLoaded)
    XCTAssertEqual(store.state.suggestion?.suggestions.first?.term, "Rivaroxaban")
    await store.send(.applySuggestion("Rivaroxaban"))
    XCTAssertEqual(store.state.text.string, "Patient erhielt Rivaroxaban")
    XCTAssertEqual(store.state.learnCandidates.first?.original, "Ribaroxaban")
  }

  /// B5: spelling mode turns the next dictation into letters.
  func testSpellingMode() async throws {
    let store = makeStore()
    await store.send(.present(targetBundleID: nil, targetAppName: nil, mode: .literal))
    await store.send(.toggleSpellingMode)
    await store.send(.dictationFinished(output("Anton Paula Ida Xanthippe Anton Berta Anton Nordpol"), try tempAudio()))
    XCTAssertEqual(store.state.text.string, "APIXABAN")
    XCTAssertFalse(store.state.spellingMode)
    XCTAssertEqual(store.state.learnCandidates.first?.replacement, "APIXABAN")
  }

  func testVoiceCommandsInBox() async throws {
    let pasted = LockIsolated<[RichPastePayload]>([])
    let store = makeStore(pasted: pasted)
    await store.send(.present(targetBundleID: nil, targetAppName: nil, mode: .literal))
    await store.send(.dictationFinished(output("Satz eins Punkt"), try tempAudio()))
    await store.send(.dictationFinished(output("Satz zwei Punkt"), try tempAudio()))
    // „streich das“ as its own dictation removes the previous dictation.
    await store.send(.dictationFinished(output("streich das"), try tempAudio()))
    XCTAssertEqual(store.state.text.string, "Satz eins.")
    await store.send(.dictationFinished(output("buchstabieren"), try tempAudio()))
    XCTAssertTrue(store.state.spellingMode)
    await store.send(.toggleSpellingMode)
    await store.send(.dictationFinished(output("Text übertragen"), try tempAudio()))
    await store.receive(\.confirmTapped)
    await store.receive(\.close)
    XCTAssertEqual(pasted.value.first?.plain, "Satz eins.")
  }

  /// B7: discarding a long text asks first.
  func testDiscardLongTextAsks() async throws {
    let store = makeStore()
    await store.send(.present(targetBundleID: nil, targetAppName: nil, mode: .literal))
    let long = (1...25).map { "Wort\($0)" }.joined(separator: " ")
    let audio = try tempAudio()
    await store.send(.dictationFinished(output(long), audio))
    await store.send(.discardTapped)
    XCTAssertTrue(store.state.isConfirmingDiscard)
    await store.send(.discardConfirmed)
    XCTAssertFalse(store.state.isPresented)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
  }

  func testMarkdownFormatPastesMarkup() async throws {
    let pasted = LockIsolated<[RichPastePayload]>([])
    let store = makeStore(pasted: pasted)
    await store.send(.present(targetBundleID: nil, targetAppName: nil, mode: .literal))
    await store.send(.setFormat(.markdown))
    await store.send(.dictationFinished(output("das ist fett an wichtig fett aus"), try tempAudio()))
    await store.send(.confirmTapped)
    await store.receive(\.close)
    XCTAssertEqual(pasted.value.first?.plain, "Das ist **wichtig**")
    XCTAssertNil(pasted.value.first?.rtf)
  }
}
