import Foundation
import HexCore
import LocalLLM
import XCTest

@testable import Hex

/// Diagnostic only (runs when /private/tmp/LocalASR-Streaming/idle-probe exists):
/// does work with each engine, then stays idle so CPU/energy can be sampled
/// from outside. Phases are written to idle-probe.log with timestamps.
final class IdleEnergyProbeTests: XCTestCase {
  private let dir = URL(fileURLWithPath: "/private/tmp/LocalASR-Streaming", isDirectory: true)

  private func mark(_ text: String) {
    let line = "\(Date().timeIntervalSince1970) \(text)\n"
    let url = dir.appendingPathComponent("idle-probe.log")
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
    } else {
      try? line.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  func testIdleAfterEngines() async throws {
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("idle-probe").path) else { throw XCTSkip("probe only on request") }
    MLXMemoryPolicy.apply()
    let samples = [Float](repeating: 0, count: 16_000 * 10)
    mark("baseline-idle"); try await Task.sleep(for: .seconds(20))

    let nemotron = try await StreamingEngineHost.shared.nemotronEngine(chunkMs: 1120)
    try await nemotron.begin(language: "de"); _ = try await nemotron.feed(samples); _ = try await nemotron.end()
    mark("nemotron-idle"); try await Task.sleep(for: .seconds(25))
    await StreamingEngineHost.shared.unloadAll()

    let voxtral = try await StreamingEngineHost.shared.voxtralEngine()
    try await voxtral.begin(language: "de"); _ = try await voxtral.feed(samples); _ = try await voxtral.end()
    mark("voxtral-idle"); try await Task.sleep(for: .seconds(25))
    await StreamingEngineHost.shared.unloadAll()
    mark("after-unload-idle"); try await Task.sleep(for: .seconds(20))

    let llmDir = URL(fileURLWithPath: NSHomeDirectory() + "/.lmstudio/models/mlx-community/Qwen3.5-4B-MLX-4bit")
    if FileManager.default.fileExists(atPath: llmDir.path) {
      let engine = LocalLLMEngine()
      try await engine.load(directory: llmDir)
      _ = try await engine.generate(system: "Fix the text.", user: "hallo welt das ist ein test", maxTokens: 40)
      mark("llm-loaded-idle"); try await Task.sleep(for: .seconds(25))
      await engine.unload()
      mark("llm-unloaded-idle"); try await Task.sleep(for: .seconds(20))
    }
    mark("done")
  }
}
