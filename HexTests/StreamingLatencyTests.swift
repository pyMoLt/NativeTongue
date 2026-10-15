import AudioCommon
import Foundation
import HexCore
import XCTest

@testable import Hex

/// How long after a word is spoken it gets typed, per streaming engine.
///
/// Feeds a private recording in 100 ms chunks at real-time pace (as the microphone
/// would) and maps each typed word to the end time of the same word in a batch
/// transcript with word timings (Parakeet Ultra, Core ML). Opt-in because it runs in
/// real time: set TEST_RUNNER_LOCAL_ASR_LATENCY=1. Results go to
/// /private/tmp/LocalASR-Streaming/latency-*.txt.
final class StreamingLatencyTests: XCTestCase {
  private let reportDirectory = URL(fileURLWithPath: "/private/tmp/LocalASR-Streaming", isDirectory: true)
  private let clips = ["2026-10-15/N2-lang.m4a", "2026-10-15/L3-fliessend.m4a"]

  private func enabled() throws {
    guard ProcessInfo.processInfo.environment["LOCAL_ASR_LATENCY"] == "1" else { throw XCTSkip("set TEST_RUNNER_LOCAL_ASR_LATENCY=1") }
  }

  private func fixture(_ name: String) throws -> [Float] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("dev-docs/04-tests/audio/\(name)")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private audio fixture missing") }
    return try AudioFileLoader.load(url: url, targetSampleRate: 16_000)
  }

  /// Word end times from a batch transcript (reference clock).
  private func referenceWordEnds(_ samples: [Float]) async throws -> [Double] {
    let client = TranscriptionClient.liveValue
    guard await client.isModelDownloaded("parakeet-ultra-coreml") else { throw XCTSkip("Parakeet Ultra (Core ML) not installed") }
    let result = try await client.transcribeSamples(samples, "parakeet-ultra-coreml", RequestOptions(language: "de", punctuation: .natural))
    return result.words.map(\.end)
  }

  private struct Timeline {
    var typed: [Double] = []   // wall-clock second at which committed word k appeared
    var shown: [Double] = []   // … at which word k first appeared as committed or pending
    var processing = 0.0
  }

  private func run(_ engine: any StreamingEngine, _ samples: [Float]) async throws -> Timeline {
    try await engine.begin(language: "de")
    var line = Timeline()
    var committed = ""
    let start = Date()
    var index = 0
    func note(_ update: StreamingUpdate, at now: Double) {
      committed += update.committed
      let typedWords = committed.split(whereSeparator: \.isWhitespace).count
      while line.typed.count < typedWords { line.typed.append(now) }
      let shownWords = (committed + " " + update.pending).split(whereSeparator: \.isWhitespace).count
      while line.shown.count < shownWords { line.shown.append(now) }
    }
    while index < samples.count {
      let end = min(index + 1_600, samples.count)
      let feedStart = Date()
      let update = try await engine.feed(Array(samples[index..<end]))
      line.processing += Date().timeIntervalSince(feedStart)
      note(update, at: Date().timeIntervalSince(start))
      index = end
      // Real-time pace: the next chunk exists only once it has been spoken.
      let ahead = Double(index) / 16_000 - Date().timeIntervalSince(start)
      if ahead > 0 { try await Task.sleep(for: .seconds(ahead)) }
    }
    note(try await engine.end(), at: Date().timeIntervalSince(start))
    return line
  }

  private func lags(_ times: [Double], reference: [Double]) -> [Double] {
    guard !times.isEmpty, !reference.isEmpty else { return [] }
    return times.indices.map { k in
      let r = min(reference.count - 1, Int((Double(k) * Double(reference.count) / Double(times.count)).rounded(.down)))
      return times[k] - reference[r]
    }
  }

  private func summary(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "-" }
    let sorted = values.sorted()
    func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
    return String(format: "median %.1f s, p90 %.1f s, max %.1f s", q(0.5), q(0.9), sorted.last!)
  }

  private func measure(_ name: String, engine: () async throws -> any StreamingEngine) async throws {
    try enabled()
    var body = "engine: \(name)\n"
    for clip in clips {
      let samples = try fixture(clip)
      let reference = try await referenceWordEnds(samples)
      let line = try await run(try await engine(), samples)
      let seconds = Double(samples.count) / 16_000
      body += String(format: "%@ (%.0f s, %d words): typed %@ | shown %@ | compute %.2f× real time\n",
                     clip, seconds, line.typed.count, summary(lags(line.typed, reference: reference)),
                     summary(lags(line.shown, reference: reference)), line.processing / seconds)
      XCTAssertGreaterThan(line.typed.count, 20)
    }
    try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    try body.write(to: reportDirectory.appendingPathComponent("latency-\(name).txt"), atomically: true, encoding: .utf8)
    await StreamingEngineHost.shared.unloadAll()
  }

  func testCoreAIParakeetLatency() async throws {
    guard #available(macOS 27.0, *) else { throw XCTSkip("Core AI needs macOS 27") }
    guard CoreAIParakeetStore.isInstalled() else { throw XCTSkip("Parakeet Ultra (Core AI) not installed") }
    try await measure("parakeet-ultra-coreai") { try await StreamingEngineHost.shared.coreAIParakeetEngine() }
  }

  func testNemotronLatency() async throws {
    guard NemotronStreamingEngine.isInstalled(chunkMs: 1_120) else { throw XCTSkip("Nemotron not installed") }
    try await measure("nemotron-1120") { try await StreamingEngineHost.shared.nemotronEngine(chunkMs: 1_120) }
  }

  /// Delays from LOCAL_ASR_VOXTRAL_DELAYS ("240,480,960"), default the model's 480 ms.
  func testVoxtralLatency() async throws {
    guard VoxtralStreamingEngine.isInstalled() else { throw XCTSkip("Voxtral not installed") }
    let delays = (ProcessInfo.processInfo.environment["LOCAL_ASR_VOXTRAL_DELAYS"] ?? "480").split(separator: ",").compactMap { Int($0) }
    for delay in delays {
      try await measure("voxtral-\(delay)") { try await StreamingEngineHost.shared.voxtralEngine(delayMs: delay) }
    }
  }
}
