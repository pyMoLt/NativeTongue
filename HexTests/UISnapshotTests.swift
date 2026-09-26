import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI
import XCTest

@testable import Hex

/// Renders every page light + dark into PNGs for review (plan phase 6).
/// Output: $LOCAL_ASR_UI_SNAPSHOT_DIR or /private/tmp/LocalASR-UI. No assertions on pixels.
@MainActor
final class UISnapshotTests: XCTestCase {
  private let outputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCAL_ASR_UI_SNAPSHOT_DIR"] ?? "/private/tmp/LocalASR-UI", isDirectory: true)

  private func appState(tab: AppFeature.ActiveTab, mode: DictationMode = .literal) -> AppFeature.State {
    var settings = HexSettings()
    settings.selectedModel = "openai_whisper-large-v3-v20240930_turbo"
    settings.dictationMode = mode
    settings.asrProfile = .medical
    settings.hasCompletedV2Onboarding = true
    settings.activeLexiconPacks = ["medical-de", "technical"]
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
      LexiconEntry(term: "ST-Hebungsinfarkt", lang: "de", category: "user", aliases: ["ST Hebungsinfarkt"], autoReplace: true, profile: .medical),
      LexiconEntry(term: "Qwen", lang: "en", category: "user", aliases: ["Gwen", "Quen"], autoReplace: true),
      LexiconEntry(term: "Mycophenolatmofetil", lang: "de", category: "user", autoReplace: true, profile: .medical),
    ]
    state.lexicon.packs = [
      LexiconPackInfo(id: "medical-de", version: "1", license: "CC0 / GPL-3.0 / BfArM lokal", entryCount: 104_467, fileBytes: 10_570_986),
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
    try render(MenuPanelView(store: store) {}, name: "10-menueleiste", size: NSSize(width: 300, height: 330))
    try render(AppView(store: makeStore(appState(tab: .dictation))), name: "01b-diktat-schmal", size: NSSize(width: 640, height: 900))

    var hudState = appState(tab: .dictation)
    hudState.transcription.isRecording = true
    hudState.transcription.recordingStartTime = Date().addingTimeInterval(-42)
    hudState.transcription.meter = .init(averagePower: 0.18, peakPower: 0.3)
    try render(
      VStack(spacing: 14) {
        TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.18, peakPower: 0.3), mode: .literal, recordingStart: Date().addingTimeInterval(-42))
        TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0), mode: .normal)
      }
      .padding(30)
      .background(LinearGradient(colors: [.teal.opacity(0.5), .indigo.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)),
      name: "11-hud",
      size: NSSize(width: 420, height: 170)
    )

    var boxState = hudState
    boxState.dictationBox.isPresented = true
    boxState.dictationBox.mode = .literal
    boxState.dictationBox.targetAppName = "Pages"
    let markdown = "# Befund\nDer Patient erhielt Rivaroxaban 20 mg und Mycophenolatmofetil.\n- Kein Hinweis auf eine Thrombose.\n- **ST-Hebungsinfarkt** ausgeschlossen."
    boxState.dictationBox.text = BoxText(BoxTextConverter.attributed(
      fromMarkdown: markdown,
      baseFont: BoxTextStyle.baseFont(name: "", size: 15),
      corrections: [LexiconCorrection(original: "Mycophenolatmophetil", replacement: "Mycophenolatmofetil", rule: .fuzzy)]
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

    var onboarding = appState(tab: .dictation)
    onboarding.microphonePermission = .granted
    onboarding.accessibilityPermission = .notDetermined
    try render(OnboardingView(store: makeStore(onboarding)), name: "13-onboarding", size: NSSize(width: 620, height: 470))
  }
}
