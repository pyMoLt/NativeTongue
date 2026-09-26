import ComposableArchitecture
import HexCore
import XCTest

@testable import Hex

@MainActor
final class LocalASRAudioImportEligibilityTests: XCTestCase {
  func testAudioImportRequiresFileAndInstalledSelectedModel() {
    var settings = HexSettings()
    settings.selectedModel = "local-whisper"
    var state = AudioImportFeature.State(hexSettings: Shared(value: settings))

    XCTAssertFalse(state.canTranscribe)

    state.selectedFileURL = URL(fileURLWithPath: "/private/tmp/input.wav")
    XCTAssertFalse(state.canTranscribe)

    state.modelAvailabilityIdentifier = "another-model"
    state.isSelectedModelInstalled = true
    XCTAssertFalse(state.canTranscribe)

    state.modelAvailabilityIdentifier = "local-whisper"
    XCTAssertTrue(state.canTranscribe)
  }

  func testAudioImportCannotStartWhileAlreadyTranscribing() {
    var settings = HexSettings()
    settings.selectedModel = "local-whisper"
    var state = AudioImportFeature.State(hexSettings: Shared(value: settings))
    state.selectedFileURL = URL(fileURLWithPath: "/private/tmp/input.wav")
    state.modelAvailabilityIdentifier = "local-whisper"
    state.isSelectedModelInstalled = true
    state.isTranscribing = true

    XCTAssertFalse(state.canTranscribe)
  }

  func testAudioDropAcceptsLocalAudioFilesOnly() {
    XCTAssertTrue(AudioImportFileValidator.isSupportedAudioFile(
      URL(fileURLWithPath: "/private/tmp/example.wav")
    ))
    XCTAssertTrue(AudioImportFileValidator.isSupportedAudioFile(
      URL(fileURLWithPath: "/private/tmp/example.m4a")
    ))
    XCTAssertFalse(AudioImportFileValidator.isSupportedAudioFile(
      URL(fileURLWithPath: "/private/tmp/example.txt")
    ))
    XCTAssertFalse(AudioImportFileValidator.isSupportedAudioFile(
      URL(string: "https://example.com/example.wav")!
    ))
  }
}
