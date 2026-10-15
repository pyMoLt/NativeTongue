import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI
import XCTest

@testable import Hex

/// Renders every page light + dark into PNGs for review (plan phase 6).
/// Output: $LOCAL_ASR_UI_SNAPSHOT_DIR or <temporary directory>/LocalASR-UI (writable for any test host). No assertions on pixels.
@MainActor
final class UISnapshotTests: XCTestCase {
  private let outputDirectory = ProcessInfo.processInfo.environment["LOCAL_ASR_UI_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent("LocalASR-UI", isDirectory: true)

  private func appState(tab: AppFeature.ActiveTab, mode: DictationMode = .literal) -> AppFeature.State {
    var settings = HexSettings()
    settings.selectedModel = "openai_whisper-large-v3-v20240930_turbo"
    settings.dictationMode = mode
    settings.asrProfile = .technical
    settings.hasCompletedV2Onboarding = true
    settings.activeLexiconPacks = ["technical"]
    var state = AppFeature.State(hexSettings: Shared(value: settings), modelBootstrapState: Shared(value: ModelBootstrapState(isModelReady: true)))
    state.activeTab = tab
    state.modelStatus = .init(loadedModel: "openai_whisper-large-v3-v20240930_turbo", footprintMB: 1_795)
    state.microphonePermission = .granted
    state.accessibilityPermission = .granted
    state.inputMonitoringPermission = .granted
    state.settings = SettingsFeature.State(hexSettings: Shared(value: settings))
    state.settings.modelDownload.availableModels = IdentifiedArray(uniqueElements: LocalASRModelCatalog.bundled.map {
      ModelInfo(name: $0.internalName, isDownloaded: ["openai_whisper-large-v3-v20240930_turbo", "parakeet-ultra-coreml", "qwen3-asr-1.7b-8bit-mlx"].contains($0.internalName))
    })
    state.lexicon = LexiconFeature.State(hexSettings: Shared(value: settings))
    state.lexicon.userEntries = [
      LexiconEntry(term: "NativeTongue", lang: "en", category: "user", aliases: ["Native Tongue"], autoReplace: true, profile: .technical),
      LexiconEntry(term: "Qwen", lang: "en", category: "user", aliases: ["Gwen", "Quen"], autoReplace: true),
      LexiconEntry(term: "WhisperKit", lang: "en", category: "user", autoReplace: true, profile: .technical),
    ]
    state.lexicon.packs = [
      LexiconPackInfo(id: "technical", version: "1", license: "MIT / CC0", entryCount: 13_740, fileBytes: 1_244_173),
    ]
    return state
  }

  private func makeStore(_ state: AppFeature.State) -> StoreOf<AppFeature> {
    Store(initialState: state) { EmptyReducer() }
  }

  private func render(_ view: some View, name: String, size: NSSize) throws {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "hell"), (.darkAqua, "dunkel")] {
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearanceName)
      let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
      hosting.frame = NSRect(origin: .zero, size: size)
      window.contentView = hosting
      window.layoutIfNeeded()
      hosting.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
      hosting.displayIfNeeded()
      guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
      hosting.cacheDisplay(in: hosting.bounds, to: rep)
      let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      try data.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
      window.close()
    }
  }

  func testRenderPages() throws {
    let pages: [(AppFeature.ActiveTab, String)] = [
      (.dictation, "01-diktat"), (.models, "02-modelle"), (.vocabulary, "03-wortschatz"),
      (.commands, "04-befehle"), (.dictationBox, "05-diktierbox-einstellungen"), (.settings, "06-einstellungen"),
    ]
    for (tab, name) in pages {
      try render(AppView(store: makeStore(appState(tab: tab))), name: name, size: NSSize(width: 1_040, height: 760))
    }
  }

  func testRenderFloatingSurfaces() throws {
    let store = makeStore(appState(tab: .dictation))
    @Shared(.lastTranscript) var last: LastTranscript? = nil
    $last.withLock { $0 = LastTranscript(text: "Please refactor the ContentView so that the settings sheet uses the new glass buttons and keeps its state.", date: Date().addingTimeInterval(-120), appName: "Xcode") }
    try render(MenuPanelView(store: store) {}, name: "10-menueleiste", size: NSSize(width: 300, height: 360))
    try render(AppView(store: makeStore(appState(tab: .dictation))), name: "01b-diktat-schmal", size: NSSize(width: 640, height: 900))

    var hudState = appState(tab: .dictation)
    hudState.transcription.isRecording = true
    hudState.transcription.recordingStartTime = Date().addingTimeInterval(-42)
    hudState.transcription.meter = .init(averagePower: 0.18, peakPower: 0.3)
    try render(
      VStack(spacing: 14) {
        TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.18, peakPower: 0.3), mode: .literal, recordingStart: Date().addingTimeInterval(-42))
        TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0), mode: .normal)
        TranscriptionIndicatorView(status: .polishing, meter: .init(averagePower: 0, peakPower: 0), mode: .normal)
        TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0), mode: .normal, showsWarning: true)
      }
      .padding(30)
      .background(LinearGradient(colors: [.teal.opacity(0.5), .indigo.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)),
      name: "11-hud",
      size: NSSize(width: 420, height: 270)
    )

    var boxState = hudState
    boxState.dictationBox.isPresented = true
    boxState.dictationBox.mode = .literal
    boxState.dictationBox.targetAppName = "Pages"
    let markdown = "# Besprechung\nDas Update nutzt WhisperKit und Qwen für lokale Transkription.\n- Latenz unter 200 ms.\n- **NativeTongue** läuft komplett offline."
    boxState.dictationBox.text = BoxText(BoxTextConverter.attributed(
      fromMarkdown: markdown,
      baseFont: BoxTextStyle.baseFont(name: "", size: 15),
      corrections: [LexiconCorrection(original: "WhisprKit", replacement: "WhisperKit", rule: .fuzzy)]
    ))
    boxState.dictationBox.revision = 1
    boxState.dictationBox.lastAction = "¶ Neuer Absatz"
    let boxStore = makeStore(boxState)
    try render(
      DictationBoxView(
        store: boxStore.scope(state: \.dictationBox, action: \.dictationBox),
        transcription: boxStore.scope(state: \.transcription, action: \.transcription)
      ),
      name: "12-diktierbox",
      size: NSSize(width: 680, height: 380)
    )

    var aiBox = boxState
    aiBox.dictationBox.hexSettings.postProcessing.enabled = true
    aiBox.dictationBox.aiPhase = .done
    aiBox.dictationBox.isShowingDiff = true
    aiBox.dictationBox.aiOriginalText = "das update nutzt whisperkit und qwen mit unter 200 ms latenz komplett offline"
    aiBox.dictationBox.aiResultText = "Das Update nutzt WhisperKit und Qwen mit unter 200 ms Latenz. Komplett offline."
    aiBox.dictationBox.aiIssues = [PolishGuardIssue(kind: .numberChanged, detail: "200 ms")]
    let aiBoxStore = makeStore(aiBox)
    try render(
      DictationBoxView(
        store: aiBoxStore.scope(state: \.dictationBox, action: \.dictationBox),
        transcription: aiBoxStore.scope(state: \.transcription, action: \.transcription)
      ),
      name: "14-diktierbox-ki-diff",
      size: NSSize(width: 680, height: 520)
    )

    var aiPage = appState(tab: .postProcessing)
    aiPage.settings.hexSettings.postProcessing.enabled = true
    aiPage.settings.hexSettings.postProcessing.autoEnabled = true
    try render(AppView(store: makeStore(aiPage)), name: "07-ki-nachbearbeitung", size: NSSize(width: 1_040, height: 1_500))

    var streamingPage = appState(tab: .streaming, mode: .streaming)
    streamingPage.settings.hexSettings.dictationMode = .streaming
    try render(AppView(store: makeStore(streamingPage)), name: "08-streaming", size: NSSize(width: 1_040, height: 1_450))
    try render(MenuPanelView(store: makeStore(streamingPage)) {}, name: "10b-menueleiste-streaming", size: NSSize(width: 300, height: 360))

    var onboarding = appState(tab: .dictation)
    onboarding.microphonePermission = .granted
    onboarding.accessibilityPermission = .notDetermined
    try render(OnboardingView(store: makeStore(onboarding)), name: "13-onboarding", size: NSSize(width: 620, height: 470))
  }

  /// Pages changed in 2.6 stage B (commands, vocabulary with snippets and
  /// learned corrections, recording key behaviour).
  func testRenderStageBPages() throws {
    var vocabulary = appState(tab: .vocabulary, mode: .normal)
    vocabulary.lexicon.snippets = [
      TextSnippet(trigger: "meine Adresse", text: "Alex Example\n123 Example Street\n10115 Berlin"),
      TextSnippet(trigger: "Grußformel", text: "Viele Grüße\n\nAlex"),
      TextSnippet(trigger: "meine E-Mail", text: ""),
    ]
    vocabulary.lexicon.learnedCorrections = [
      LearnedCorrection(original: "WhisprKit", replacement: "WhisperKit", count: 2),
      LearnedCorrection(original: "Vox Drill", replacement: "Voxtral", count: 1, declined: true),
    ]
    try render(AppView(store: makeStore(vocabulary)), name: "b-vocabulary", size: NSSize(width: 1_000, height: 1_700))
    try render(AppView(store: makeStore(appState(tab: .commands, mode: .normal))), name: "b-commands", size: NSSize(width: 1_000, height: 1_500))
    var recording = appState(tab: .recording, mode: .normal)
    recording.settings.hexSettings.hotkeyTapToggle = true
    try render(AppView(store: makeStore(recording)), name: "b-recording", size: NSSize(width: 1_000, height: 1_300))
  }

  /// 3.2.2: the three box styles at default and minimum size, plus the settings pages.
  func testRenderDictationBoxStyles() throws {
    func boxStore(_ style: DictationBoxStyle, scale: Double = 1, colors: (String, String)? = nil, ownLook: Bool = false) -> StoreOf<AppFeature> {
      var state = appState(tab: .dictation)
      var settings = HexSettings()
      settings.selectedModel = "openai_whisper-large-v3-v20240930_turbo"
      settings.postProcessing.enabled = true
      settings.appearance.dictationBox.style = style
      settings.appearance.dictationBox.scale = scale
      if ownLook {
        settings.appearance.accent = .coral
        settings.appearance.background = .vivid
        settings.appearance.dictationBox.followsApp = false
      }
      if let colors {
        settings.appearance.dictationBox.minimalBackground = colors.0
        settings.appearance.dictationBox.minimalText = colors.1
      }
      state.dictationBox = DictationBoxFeature.State(hexSettings: Shared(value: settings))
      state.dictationBox.isPresented = true
      state.dictationBox.isVisible = true
      state.dictationBox.mode = .literal
      state.dictationBox.targetAppName = "Pages"
      let markdown = "# Besprechung\nDas Update nutzt WhisperKit und Qwen für lokale Transkription.\n- Latenz unter 200 ms."
      state.dictationBox.text = BoxText(BoxTextConverter.attributed(fromMarkdown: markdown, baseFont: BoxTextStyle.baseFont(name: "", size: 15)))
      state.dictationBox.revision = 1
      state.dictationBox.lastAction = "¶ Neuer Absatz"
      return makeStore(state)
    }
    func box(_ store: StoreOf<AppFeature>) -> some View {
      DictationBoxView(
        store: store.scope(state: \.dictationBox, action: \.dictationBox),
        transcription: store.scope(state: \.transcription, action: \.transcription)
      )
    }
    for style in DictationBoxStyle.allCases {
      let normal = DictationBoxMetrics.defaultSize(style)
      let minimum = DictationBoxMetrics.minimumSize(style)
      try render(box(boxStore(style)), name: "box-\(style.rawValue)-standardgroesse", size: NSSize(width: normal.width, height: normal.height))
      try render(box(boxStore(style)), name: "box-\(style.rawValue)-minimum", size: NSSize(width: minimum.width, height: minimum.height))
    }
    try render(box(boxStore(.standard)), name: "box-standard-schmal-500", size: NSSize(width: 500, height: 300))
    try render(box(boxStore(.compact, scale: 1.3)), name: "box-compact-130prozent", size: NSSize(width: 520 * 1.3, height: 260 * 1.3))
    try render(box(boxStore(.minimal, colors: ("#1E2A38", "#F2E9D8"))), name: "box-minimal-eigene-farben", size: NSSize(width: 460, height: 200))
    try render(box(boxStore(.standard, ownLook: true)), name: "box-standard-eigenes-aussehen", size: NSSize(width: 640, height: 360))
    try render(box(boxStore(.standard)), name: "box-standard-wie-app", size: NSSize(width: 640, height: 360))

    var appearancePage = appState(tab: .appearance)
    appearancePage.settings.hexSettings.appearance.dictationBox.style = .minimal
    appearancePage.settings.hexSettings.appearance.dictationBox.followsApp = false
    try render(AppView(store: makeStore(appearancePage)), name: "box-einstellung-darstellung", size: NSSize(width: 1_040, height: 1_300))
    var boxPage = appState(tab: .dictationBox)
    boxPage.settings.hexSettings.boxOpenTiming = .immediately
    try render(AppView(store: makeStore(boxPage)), name: "box-einstellung-verhalten", size: NSSize(width: 1_040, height: 1_100))
  }
}
