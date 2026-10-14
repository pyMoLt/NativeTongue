import AppKit
import ComposableArchitecture
import HexCore
import LocalLLM
import XCTest

@testable import Hex

@MainActor
final class PostProcessingTests: XCTestCase {
  private func settings(enabled: Bool = true, auto: Bool = true, mode: DictationMode = .normal) -> HexSettings {
    var settings = HexSettings()
    settings.dictationMode = mode
    settings.postProcessing.enabled = enabled
    settings.postProcessing.autoEnabled = auto
    return settings
  }

  func testAutomaticPolishRunsOnlyWhenEnabled() {
    let text = "das ist ein test mit fünf wörtern"
    XCTAssertNotNil(TranscriptionFeature.automaticPolish(for: text, settings: settings()))
    XCTAssertNil(TranscriptionFeature.automaticPolish(for: text, settings: settings(enabled: false)))
    XCTAssertNil(TranscriptionFeature.automaticPolish(for: text, settings: settings(auto: false)))
  }

  func testAutomaticPolishRespectsScopeAndMinimumWords() {
    XCTAssertNil(TranscriptionFeature.automaticPolish(for: "zu kurz", settings: settings()))
    let literal = settings(mode: .literal)
    XCTAssertNil(TranscriptionFeature.automaticPolish(for: "das ist ein langer literal text", settings: literal))
    var both = literal
    both.postProcessing.autoScope = .normalAndLiteralWithoutBox
    XCTAssertNotNil(TranscriptionFeature.automaticPolish(for: "das ist ein langer literal text", settings: both))
  }

  func testAutomaticPolishUsesExactlyTheSelectedModel() {
    var selected = settings()
    selected.postProcessing.autoModel = "lfm25-1.2b-8bit"
    let request = TranscriptionFeature.automaticPolish(for: "das ist ein test mit fünf wörtern", settings: selected)
    XCTAssertEqual(request?.modelID, "lfm25-1.2b-8bit")
    XCTAssertEqual(request?.style.id, AIStyleCatalog.cleanID)
    // No silent default: without a selection the request fails visibly (original + ⚠︎).
    XCTAssertEqual(TranscriptionFeature.automaticPolish(for: "das ist ein test mit fünf wörtern", settings: settings())?.modelID, "")
  }

  func testBoxAndAutomaticUseTheChosenStyleIncludingOwnStyles() async {
    var hexSettings = HexSettings()
    hexSettings.postProcessing.enabled = true
    hexSettings.postProcessing.autoEnabled = true
    hexSettings.postProcessing.boxModel = "qwen35-4b-4bit"
    var protocolStyle = AIStyle.newCustom(name: "Protocol")
    protocolStyle.instruction = "Write a short protocol."
    protocolStyle.strictness = .off
    hexSettings.postProcessing.save(protocolStyle)
    hexSettings.postProcessing.autoStyleID = protocolStyle.id

    // Automatic step: the chosen own style, with its strictness.
    let auto = TranscriptionFeature.automaticPolish(for: "das ist ein test mit fünf wörtern", settings: hexSettings)
    XCTAssertEqual(auto?.style.id, protocolStyle.id)
    XCTAssertEqual(auto?.style.strictness, .off)

    // Box: the ✨ menu passes the picked style through to the model.
    var state = DictationBoxFeature.State(hexSettings: Shared(value: hexSettings))
    state.isPresented = true
    state.text = BoxText(NSAttributedString(string: "hallo herr berger der bericht kommt freitag"))
    let store = TestStore(initialState: state) {
      DictationBoxFeature()
    } withDependencies: {
      $0.lexicon.userLexicon = { UserLexicon() }
      $0.llm.isInstalled = { _ in true }
      $0.llm.polish = { request, _, _ in
        XCTAssertEqual(request.style.id, AIStyleCatalog.emailID)
        XCTAssertTrue(PolishPrompt.system(for: request.style, settings: request.settings).contains("e-mail"))
        return PolishOutcome(text: "Hallo Herr Berger,", original: request.text, aiText: "Hallo Herr Berger,", issues: [], failed: false)
      }
    }
    store.exhaustivity = .off
    await store.send(.aiTapped(AIStyleCatalog.emailID))
    await store.receive(\.aiFinished)
    XCTAssertEqual(store.state.text.string, "Hallo Herr Berger,")
  }

  func testBoxFollowsTheProfileOfItsTargetApp() async {
    var hexSettings = HexSettings()
    hexSettings.postProcessing.enabled = true
    hexSettings.postProcessing.boxModel = "qwen35-4b-4bit"
    var state = DictationBoxFeature.State(hexSettings: Shared(value: hexSettings))
    state.targetBundleID = "com.apple.mail"
    XCTAssertEqual(state.targetSettings.postProcessing.boxStyleID, AIStyleCatalog.emailID)
    state.targetBundleID = "com.example.other"
    XCTAssertEqual(state.targetSettings.postProcessing.boxStyleID, AIStyleCatalog.cleanID)

    var session = TranscriptionFeature.State()
    session.$hexSettings.withLock { $0 = hexSettings; $0.dictationMode = .literal }
    session.sessionAppBundleID = "com.apple.dt.Xcode"
    XCTAssertEqual(session.sessionSettings.dictationMode, .normal)
    XCTAssertTrue(session.sessionSettings.agentFormattingEnabled)
    XCTAssertEqual(session.sessionProfile.id, ProfileSettings.codingID)
    session.sessionAppBundleID = nil
    XCTAssertEqual(session.sessionSettings.dictationMode, .literal)
  }

  func testBoxAIRunReplacesTextAndOffersDiffAndRevert() async {
    var hexSettings = HexSettings()
    hexSettings.postProcessing.enabled = true
    hexSettings.postProcessing.boxModel = "qwen35-0.8b-8bit"
    var state = DictationBoxFeature.State(hexSettings: Shared(value: hexSettings))
    state.isPresented = true
    state.text = BoxText(NSAttributedString(string: "der patient bekommt 25 mg"))
    let store = TestStore(initialState: state) {
      DictationBoxFeature()
    } withDependencies: {
      $0.lexicon.userLexicon = { UserLexicon() }
      $0.llm.isInstalled = { $0.id == "qwen35-0.8b-8bit" }
      $0.llm.polish = { request, keep, _ in
        XCTAssertTrue(keep)
        XCTAssertEqual(request.modelID, "qwen35-0.8b-8bit")
        return PolishOutcome(text: "Der Patient bekommt 25 mg.", original: request.text, aiText: "Der Patient bekommt 25 mg.", issues: [], failed: false)
      }
    }
    store.exhaustivity = .off

    await store.send(.aiTapped("clean"))
    await store.receive(\.aiFinished)
    XCTAssertEqual(store.state.text.string, "Der Patient bekommt 25 mg.")
    XCTAssertEqual(store.state.aiPhase, .done)
    XCTAssertEqual(store.state.aiOriginalText, "der patient bekommt 25 mg")

    await store.send(.diffToggled)
    XCTAssertTrue(store.state.isShowingDiff)

    await store.send(.aiRevertTapped)
    XCTAssertEqual(store.state.text.string, "der patient bekommt 25 mg")
    XCTAssertEqual(store.state.aiPhase, .idle)
  }

  /// Audit M5: dictating while the AI runs restores the original and appends,
  /// instead of mixing a half-finished AI text with the dictation.
  func testDictationDuringBoxAIRestoresOriginalAndCancelsAI() async throws {
    var hexSettings = HexSettings()
    hexSettings.postProcessing.enabled = true
    hexSettings.postProcessing.boxModel = "qwen35-0.8b-8bit"
    var state = DictationBoxFeature.State(hexSettings: Shared(value: hexSettings))
    state.isPresented = true
    state.text = BoxText(NSAttributedString(string: "der patient bekommt 25 mg"))
    state.selection = NSRange(location: 25, length: 0)
    let started = LockIsolated(false)
    let store = TestStore(initialState: state) {
      DictationBoxFeature()
    } withDependencies: {
      $0.lexicon.userLexicon = { UserLexicon() }
      $0.llm.isInstalled = { $0.id == "qwen35-0.8b-8bit" }
      $0.llm.polish = { request, _, onText in
        onText?("Der Patient")
        started.setValue(true)
        try? await Task.sleep(for: .seconds(30))
        return PolishOutcome(text: "Der Patient bekommt 25 mg.", original: request.text, aiText: "Der Patient bekommt 25 mg.", issues: [], failed: false)
      }
    }
    store.exhaustivity = .off

    await store.send(.aiTapped("clean"))
    while !started.value { await Task.yield() }
    await store.receive(\.aiPartial)
    XCTAssertEqual(store.state.text.string, "Der Patient")

    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("box-ai-\(UUID().uuidString).wav")
    try Data([0]).write(to: audio)
    defer { try? FileManager.default.removeItem(at: audio) }
    let aligned = [AlignedUtterance(utterance: Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: 900, pauseAfterMs: 900), text: "Kontrolle morgen")]
    let document = DictationSessionProcessor.makeDocument(from: aligned, options: .init(mode: .normal, formatNumbers: false, boxOpen: true))
    let output = DictationSessionOutput(document: document, language: "de", text: document.render(.init(language: "de", mode: .normal)), markdown: document.render(.init(language: "de", mode: .normal, format: .markdown)), rawText: "Kontrolle morgen")
    await store.send(.dictationFinished(output, audio))
    XCTAssertEqual(store.state.aiPhase, .idle)
    XCTAssertTrue(store.state.text.string.hasPrefix("der patient bekommt 25 mg"), store.state.text.string)
    XCTAssertTrue(store.state.text.string.contains("Kontrolle morgen"), store.state.text.string)
    XCTAssertFalse(store.state.text.string.contains("Der Patient"))
    await store.finish(timeout: .seconds(2))
  }

  func testBoxAIFailureLeavesTextUnchanged() async {
    var hexSettings = HexSettings()
    hexSettings.postProcessing.enabled = true
    hexSettings.postProcessing.boxModel = "qwen35-2b-8bit"
    var state = DictationBoxFeature.State(hexSettings: Shared(value: hexSettings))
    state.text = BoxText(NSAttributedString(string: "unverändert bleiben"))
    let store = TestStore(initialState: state) {
      DictationBoxFeature()
    } withDependencies: {
      $0.lexicon.userLexicon = { UserLexicon() }
      $0.llm.isInstalled = { _ in true }
      $0.llm.polish = { request, _, _ in
        PolishOutcome(text: request.text, original: request.text, aiText: nil, issues: [], failed: true)
      }
    }
    store.exhaustivity = .off
    await store.send(.aiTapped("task"))
    await store.receive(\.aiFinished)
    XCTAssertEqual(store.state.text.string, "unverändert bleiben")
    XCTAssertEqual(store.state.aiPhase, .idle)
    XCTAssertTrue(store.state.lastAction.contains("failed"))
  }

  func testBoxAIWithoutInstalledSelectionDoesNotSwitchModels() async {
    for (selected, message) in [("", "No AI model selected"), ("qwen35-4b-4bit", "not installed")] {
      var hexSettings = HexSettings()
      hexSettings.postProcessing.enabled = true
      hexSettings.postProcessing.boxModel = selected
      var state = DictationBoxFeature.State(hexSettings: Shared(value: hexSettings))
      state.text = BoxText(NSAttributedString(string: "bleibt wie es ist"))
      let store = TestStore(initialState: state) {
        DictationBoxFeature()
      } withDependencies: {
        $0.llm.isInstalled = { $0.id == "qwen35-2b-8bit" }
        $0.llm.polish = { _, _, _ in
          XCTFail("must not run another model")
          return PolishOutcome(text: "", original: "", aiText: nil, issues: [], failed: true)
        }
      }
      store.exhaustivity = .off
      await store.send(.aiTapped("clean"))
      XCTAssertEqual(store.state.text.string, "bleibt wie es ist")
      XCTAssertEqual(store.state.aiPhase, .idle)
      XCTAssertTrue(store.state.lastAction.contains(message), store.state.lastAction)
    }
  }
}

final class LLMModelCatalogTests: XCTestCase {
  /// The recommendation is only a hint on the model cards; it is never used implicitly.
  func testRecommendationIsCatalogHintOnly() {
    XCTAssertEqual(LLMModelCatalog.recommended(for: .auto)?.id, "qwen35-4b-4bit")
    XCTAssertEqual(PostProcessingSettings().autoModel, "")
    XCTAssertEqual(PostProcessingSettings().boxModel, "")
  }
}

extension LLMModelCatalog {
  /// Test probes only: the recommended model if installed, else the first installed one.
  static func preferredInstalledForTests() -> LLMModelDescriptor? {
    let installed = all(settings: PostProcessingSettings()).filter {
      LLMModelInstaller.isInstalled(repository: $0.repository, baseDirectory: LLMHost.baseDirectory)
    }
    return installed.first { !$0.recommendedFor.isEmpty } ?? installed.first
  }
}
