import ComposableArchitecture
import HexCore
import XCTest

@testable import Hex

@MainActor
final class AudioImportFeatureTests: XCTestCase {
  func testModelAvailabilityUsesSelectedModel() async {
    let model = "local-whisper"
    let store = TestStore(initialState: makeState(model: model)) {
      AudioImportFeature()
    } withDependencies: {
      $0.transcription.isModelDownloaded = { $0 == model }
    }

    await store.send(.checkModelAvailability) {
      $0.isCheckingModel = true
      $0.modelAvailabilityIdentifier = nil
    }
    await store.receive(\.modelAvailabilityChecked) {
      $0.isCheckingModel = false
      $0.modelAvailabilityIdentifier = model
      $0.isSelectedModelInstalled = true
    }
  }

  func testTranscriptionUsesInstalledModelAndNeverAutoPastesOrDownloads() async {
    let model = "local-whisper"
    let fileURL = URL(fileURLWithPath: "/private/tmp/audio-import-test.wav")
    let requestID = UUID()
    var state = makeState(model: model)
    state.selectedFileURL = fileURL
    state.modelAvailabilityIdentifier = model
    state.isSelectedModelInstalled = true

    let store = TestStore(initialState: state) {
      AudioImportFeature()
    } withDependencies: {
      $0.transcription.transcribe = { url, selectedModel, options, _ in
        XCTAssertEqual(url, fileURL)
        XCTAssertEqual(selectedModel, model)
        XCTAssertEqual(options.decoding.language, "de")
		XCTAssertTrue(options.decoding.wordTimestamps)
		XCTAssertNil(options.terminologyContext)
        return TranscriptionOutput(text: "Hallo Komma Welt Punkt", wordTimings: [])
      }
      $0.transcription.downloadModel = { _, _ in
        XCTFail("Audio import must not download or install a model.")
      }
      $0.pasteboard.paste = { _ in
        XCTFail("Audio import must not paste into another application.")
      }
    }

    await store.send(.transcribe(requestID: requestID)) {
      $0.isTranscribing = true
      $0.activeRequestID = requestID
      $0.resultText = nil
      $0.errorMessage = nil
    }
    await store.receive(\.transcriptionCompleted) {
      $0.isTranscribing = false
      $0.activeRequestID = nil
      $0.resultText = "Hallo, Welt."
    }
  }

  func testTranscriptionIsRejectedWhenModelIsNotInstalled() async {
    let model = "local-whisper"
    var state = makeState(model: model)
    state.selectedFileURL = URL(fileURLWithPath: "/private/tmp/audio-import-test.wav")
    state.modelAvailabilityIdentifier = model
    state.isSelectedModelInstalled = false

    let store = TestStore(initialState: state) {
      AudioImportFeature()
    }

    await store.send(.transcribe(requestID: UUID())) {
      $0.errorMessage = "The selected model is not installed. Install it in Settings → Models first."
    }
    XCTAssertFalse(store.state.isTranscribing)
  }

  private func makeState(model: String) -> AudioImportFeature.State {
    var settings = HexSettings()
    settings.selectedModel = model
    settings.outputLanguage = "de"
    settings.dictationMode = .literal
    return AudioImportFeature.State(hexSettings: Shared(value: settings))
  }
}
