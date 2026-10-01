import AVFoundation
import ComposableArchitecture
import HexCore
import XCTest

@testable import Hex

@MainActor
final class FileTranscriptionTests: XCTestCase {
  func testSupportedFilesAreLocalAudioOrVideo() {
    XCTAssertTrue(AudioImportFileValidator.isSupportedAudioFile(URL(fileURLWithPath: "/private/tmp/a.wav")))
    XCTAssertTrue(AudioImportFileValidator.isSupportedAudioFile(URL(fileURLWithPath: "/private/tmp/a.m4a")))
    XCTAssertTrue(AudioImportFileValidator.isSupportedAudioFile(URL(fileURLWithPath: "/private/tmp/a.mov")))
    XCTAssertFalse(AudioImportFileValidator.isSupportedAudioFile(URL(fileURLWithPath: "/private/tmp/a.txt")))
    XCTAssertFalse(AudioImportFileValidator.isSupportedAudioFile(URL(string: "https://example.com/a.wav")!))
  }

  /// Two tone bursts separated by silence → two segments with timestamps.
  private static func makeToneFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("file-test-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    var samples = [Float](repeating: 0, count: 16_000 / 2)
    for burst in 0..<2 {
      samples += (0..<24_000).map { 0.3 * sinf(Float($0 + burst) * 2 * .pi * 220 / 16_000) }
      samples += [Float](repeating: 0, count: 16_000)
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }

  func testMediaLoaderReadsSixteenKilohertzMono() async throws {
    let url = try Self.makeToneFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let samples = try await MediaAudioLoader.loadSamples(from: url)
    XCTAssertEqual(Double(samples.count) / 16_000, 5.5, accuracy: 0.05)
  }

  func testQueueTranscribesFileIntoTimedSegments() async throws {
    let url = try Self.makeToneFile()
    defer { try? FileManager.default.removeItem(at: url) }
    var settings = HexSettings()
    settings.selectedModel = "qwen3-asr-1.7b-8bit-mlx"   // no word timings → per-utterance decoding
    settings.outputLanguage = "de"
    let calls = LockIsolated(0)
    let store = TestStore(initialState: FileTranscriptionFeature.State(hexSettings: Shared(value: settings))) {
      FileTranscriptionFeature()
    } withDependencies: {
      $0.transcription.transcribeSamples = { _, _, _ in
        calls.withValue { $0 += 1 }
        return EngineResult(text: calls.value == 1 ? "erster Teil" : "zweiter Teil", detectedLanguage: "de")
      }
      $0.lexicon.corrector = { _ in nil }
      $0.lexicon.biasTerms = { _ in [] }
    }
    store.exhaustivity = .off
    await store.send(.addFiles([url, URL(fileURLWithPath: "/private/tmp/notes.txt")]))
    await store.receive(\.processNext)
    await store.receive(\.jobFinished, timeout: .seconds(10))
    let job = try XCTUnwrap(store.state.jobs.first)
    XCTAssertEqual(store.state.jobs.count, 1)
    XCTAssertEqual(job.status, .done)
    XCTAssertEqual(job.segments.map(\.text), ["erster Teil", "zweiter Teil"])
    XCTAssertEqual(job.segments[0].start, 0.35, accuracy: 0.2)
    XCTAssertEqual(job.segments[1].start, 2.85, accuracy: 0.2)
    XCTAssertEqual(calls.value, 2)
    XCTAssertNotNil(store.state.errorMessage)  // the .txt file was skipped

    await store.send(.renameSpeaker(job.id, speaker: 0, name: "Anna"))
    await store.send(.editSegment(job.id, segment: 1, text: "Zweiter Teil, korrigiert."))
    XCTAssertEqual(store.state.jobs.first?.segments[1].text, "Zweiter Teil, korrigiert.")
  }
}
