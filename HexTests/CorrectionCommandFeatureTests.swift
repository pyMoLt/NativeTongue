import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// B1: correction commands after a normal insertion into another app.
@MainActor
final class CorrectionCommandFeatureTests: XCTestCase {
  private func makeState() -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      hexSettings: Shared(value: .init()),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: .init())
    )
  }

  private func commandOnly(_ edit: EditCommand) -> DictationSessionOutput {
    var document = DictationDocument()
    document.apply(edit)
    return DictationSessionOutput(document: document, language: "de", text: "")
  }

  func testFieldChangedDeletesNothingAndWarns() async {
    let applied = LockIsolated<[[EditCommand]]>([])
    let pasted = LockIsolated<[String]>([])
    let clock = TestClock()
    let store = TestStore(initialState: makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.insertionEditor.apply = { edits in
        applied.withValue { $0.append(edits) }
        return .targetChanged
      }
      $0.pasteboard.paste = { text in pasted.withValue { $0.append(text) } }
      $0.transcriptionTiming.sleep = { try await clock.sleep(for: $0) }
    }
    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString).wav")
    try? Data([0]).write(to: audio)

    await store.send(.sessionTranscriptionResult(commandOnly(.deleteLastUtterance), audio, 1, isRecovery: false))
    await store.receive(\.insertionEditRefused) { $0.showsPolishWarning = true }
    XCTAssertEqual(applied.value, [[.deleteLastUtterance]])
    XCTAssertEqual(pasted.value, [], "a command is never pasted as text")
    XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    await clock.advance(by: .seconds(3))
    await store.receive(\.polishWarningExpired) { $0.showsPolishWarning = false }
  }

  func testSameFieldAppliesTheCommandSilently() async {
    let applied = LockIsolated<[[EditCommand]]>([])
    let store = TestStore(initialState: makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.insertionEditor.apply = { edits in
        applied.withValue { $0.append(edits) }
        return .applied
      }
    }
    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString).wav")
    await store.send(.sessionTranscriptionResult(commandOnly(.deleteLastWords(3)), audio, 1, isRecovery: false))
    await store.finish()
    XCTAssertEqual(applied.value, [[.deleteLastWords(3)]])
  }

  func testInsertedTextIsRememberedForLaterCommands() async {
    let remembered = LockIsolated<[String]>([])
    let store = TestStore(initialState: makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.insertionEditor.remember = { text in remembered.withValue { $0.append(text) } }
      $0.pasteboard.paste = { _ in }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off
    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString).wav")
    await store.send(.sessionTranscriptionResult(DictationSessionOutput(document: DictationDocument(), language: "de", text: "Hallo Welt"), audio, 1, isRecovery: false))
    await store.finish()
    XCTAssertEqual(remembered.value, ["Hallo Welt"])
  }
}
