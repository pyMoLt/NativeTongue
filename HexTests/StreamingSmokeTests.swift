import AudioCommon
import Foundation
import HexCore
import LocalLLM
import XCTest

@testable import Hex

/// Feeds the local test recording through each installed streaming engine in
/// 100 ms chunks (as the microphone would) and records what would be typed.
/// Skipped when an engine or the private recording is not available.
final class StreamingSmokeTests: XCTestCase {
  private var memoryLog = ""
  private let reportDirectory = URL(fileURLWithPath: "/private/tmp/LocalASR-Streaming", isDirectory: true)

  override func setUp() {
    super.setUp()
    MLXMemoryPolicy.apply()
  }

  func testStreamingVocabularyCombinesActivePackAndPersonalMultiwordAliases() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-lexicon-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LexiconStore(directory: directory)
    let pack = LexiconPack(id: "technical", entries: [
      LexiconEntry(term: "AVFoundation", lang: "en", category: "tech", aliases: ["AV Foundation"])
    ])
    let source = directory.appendingPathComponent("source.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(pack).write(to: source)
    try store.importPack(from: source)
    let user = UserLexicon(entries: [
      LexiconEntry(term: "Voxtral", lang: "de", category: "user", aliases: ["Vox Drill"], autoReplace: true, profile: .technical),
      LexiconEntry(term: "Nervus vagus", lang: "la", category: "user", aliases: ["Nervus Wagus"], autoReplace: false)
    ])
    // This test reads aliases; file-protection policy for saving a user's real
    // lexicon is exercised elsewhere and can reject writes in Xcode's temp dir.
    try JSONEncoder().encode(user).write(to: store.userURL, options: .atomic)
    let service = LexiconService(store: store)
    let aliases = await service.streamingAliases(activePacks: ["technical"], profile: .technical)
    XCTAssertEqual(aliases["av foundation"], "AVFoundation")
    XCTAssertEqual(aliases["vox drill"], "Voxtral")
    XCTAssertNil(aliases["nervus wagus"])
    let inactive = await service.streamingAliases(activePacks: [], profile: .medical)
    XCTAssertNil(inactive["av foundation"])
    XCTAssertNil(inactive["vox drill"])
    let replacementPack = LexiconPack(id: "technical", entries: [
      LexiconEntry(term: "PostgreSQL", lang: "en", category: "tech", aliases: ["Postgres SQL"])
    ])
    try JSONEncoder().encode(replacementPack).write(to: source)
    _ = try await service.importPack(from: source)
    let refreshed = await service.streamingAliases(activePacks: ["technical"], profile: .technical)
    XCTAssertNil(refreshed["av foundation"])
    XCTAssertEqual(refreshed["postgres sql"], "PostgreSQL")
  }

  private func recording() throws -> [Float] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("dev-docs/04-tests/audio/Terminology-de-en.m4a")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private audio fixture missing") }
    return try AudioFileLoader.load(url: url, targetSampleRate: 16_000)
  }

  /// Streams `samples` and returns the committed text plus timing.
  private func stream(_ engine: any StreamingEngine, _ samples: [Float], language: String = "de") async throws -> (text: String, firstTextAfter: Double?, seconds: Double) {
    try await engine.begin(language: language)
    var text = ""
    var firstTextAfter: Double?
    let start = Date()
    var index = 0
    while index < samples.count {
      let end = min(index + 1_600, samples.count)
      let update = try await engine.feed(Array(samples[index..<end]))
      if firstTextAfter == nil, !update.committed.trimmingCharacters(in: .whitespaces).isEmpty {
        firstTextAfter = Double(end) / 16_000
      }
      text += update.committed
      index = end
      if (index / 1_600) % 100 == 0 {
        memoryLog += String(format: "%.0f s audio: ", Double(index) / 16_000) + MLXMemoryInfo.summary() + "\n"
      }
    }
    text += try await engine.end().committed
    return (text, firstTextAfter, Date().timeIntervalSince(start))
  }

  private func report(_ name: String, _ result: (text: String, firstTextAfter: Double?, seconds: Double), audioSeconds: Double) {
    try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    let body = memoryLog + "engine: \(name)\naudio: \(String(format: "%.1f", audioSeconds)) s, processing: \(String(format: "%.1f", result.seconds)) s, first text after \(result.firstTextAfter.map { String(format: "%.1f", $0) } ?? "-") s of audio\n\n\(result.text)\n"
    try? body.write(to: reportDirectory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
  }

  func testEmulatedStreamingWithParakeetUltra() async throws {
    let samples = try recording()
    let client = TranscriptionClient.liveValue
    let model = "parakeet-ultra-coreml"
    guard await client.isModelDownloaded(model) else { throw XCTSkip("Parakeet Ultra not installed") }
    let engine = EmulatedStreamingEngine(pauseMs: 600, maxBlockSeconds: 12) { block in
      try await client.transcribeSamples(block, model, RequestOptions(language: "de", punctuation: .natural)).text
    }
    let result = try await stream(engine, samples)
    report("emulated-parakeet-ultra", result, audioSeconds: Double(samples.count) / 16_000)
    XCTAssertGreaterThan(result.text.split(separator: " ").count, 100, result.text)
  }

  /// Runs only when /private/tmp/LocalASR-Streaming/install-nemotron exists.
  func testInstallNemotronThroughModelClient() async throws {
    guard FileManager.default.fileExists(atPath: reportDirectory.appendingPathComponent("install-nemotron").path) else {
      throw XCTSkip("install only on request")
    }
    let client = TranscriptionClient.liveValue
    do {
      try await client.downloadModel(NemotronStreamingEngine.modelName) { _ in }
      try? "ok".write(to: reportDirectory.appendingPathComponent("install-result.txt"), atomically: true, encoding: .utf8)
    } catch {
      try? "\(error)".write(to: reportDirectory.appendingPathComponent("install-result.txt"), atomically: true, encoding: .utf8)
      throw error
    }
  }

  func testNemotronStreaming() async throws {
    let chunk = StreamingSettings().nemotronChunkMs
    guard NemotronStreamingEngine.isInstalled(chunkMs: chunk) else { throw XCTSkip("Nemotron \(chunk) ms not installed") }
    let samples = try recording()
    let engine = try await StreamingEngineHost.shared.nemotronEngine(chunkMs: chunk)
    let result = try await stream(engine, samples)
    report("nemotron-\(chunk)ms", result, audioSeconds: Double(samples.count) / 16_000)
    await StreamingEngineHost.shared.unloadAll()
    XCTAssertGreaterThan(result.text.split(separator: " ").count, 100, result.text)
  }

  func testVoxtralStreaming() async throws {
    guard VoxtralStreamingEngine.isInstalled() else { throw XCTSkip("Voxtral not installed") }
    let samples = try recording()
    let engine = try await StreamingEngineHost.shared.voxtralEngine()
    let result = try await stream(engine, samples)
    report("voxtral-4bit", result, audioSeconds: Double(samples.count) / 16_000)
    await StreamingEngineHost.shared.unloadAll()
    XCTAssertGreaterThan(result.text.split(separator: " ").count, 100, result.text)
  }

  func testAppleStreaming() async throws {
    guard await AppleSpeechASRClient().isInstalled() else { throw XCTSkip("Apple speech assets not installed") }
    let samples = try recording()
    let engine = AppleStreamingEngine()
    let result = try await stream(engine, samples)
    report("apple-speechanalyzer", result, audioSeconds: Double(samples.count) / 16_000)
    XCTAssertGreaterThan(result.text.split(separator: " ").count, 100, result.text)
  }

  // MARK: - Punctuation modes on real recordings

  private func fixture(_ name: String) throws -> [Float] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("dev-docs/04-tests/audio/\(name)")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Private audio fixture missing") }
    return try AudioFileLoader.load(url: url, targetSampleRate: 16_000)
  }

  /// Raw committed deltas of an engine for a recording (as the session sees them).
  private func deltas(_ engine: any StreamingEngine, _ samples: [Float]) async throws -> [String] {
    try await engine.begin(language: "de")
    var out: [String] = []
    var index = 0
    while index < samples.count {
      let end = min(index + 1_600, samples.count)
      let update = try await engine.feed(Array(samples[index..<end]))
      if !update.committed.isEmpty { out.append(update.committed) }
      index = end
    }
    let last = try await engine.end().committed
    if !last.isEmpty { out.append(last) }
    return out
  }

  private func modesReport(_ name: String, _ deltas: [String]) {
    var body = "engine: \(name)\n\nRAW:\n\(deltas.joined())\n"
    let variants: [(String, StreamingPunctuationMode, StreamingLiteralScope)] = [
      ("normal", .automatic, .extended), ("literal-basic", .literal, .basic),
      ("literal-extended", .literal, .extended), ("normal+commands", .combined, .extended),
    ]
    for (label, mode, scope) in variants {
      var settings = StreamingSettings()
      settings.punctuationMode = mode
      settings.literalScope = scope
      settings.formatNumbers = true
      var processor = StreamingTextProcessor(options: .init(settings: settings, language: "de", englishCommands: true, aliases: [:]))
      var typed = ""
      for delta in deltas { typed += processor.push(delta) }
      typed += processor.flush()
      body += "\n--- \(label) ---\n\(typed.trimmingCharacters(in: .whitespaces))\n"
    }
    try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    try? body.write(to: reportDirectory.appendingPathComponent("modes-\(name).txt"), atomically: true, encoding: .utf8)
  }

  func testPunctuationModesOnLiteralRecording() async throws {
    let samples = try fixture("Literal-controls.m4a")
    if NemotronStreamingEngine.isInstalled(chunkMs: 1120) {
      let engine = try await StreamingEngineHost.shared.nemotronEngine(chunkMs: 1120)
      modesReport("nemotron", try await deltas(engine, samples))
    }
    if VoxtralStreamingEngine.isInstalled() {
      let engine = try await StreamingEngineHost.shared.voxtralEngine()
      modesReport("voxtral", try await deltas(engine, samples))
    }
    await StreamingEngineHost.shared.unloadAll()
    let client = TranscriptionClient.liveValue
    for model in ["parakeet-ultra-coreml", "openai_whisper-large-v3-v20240930_turbo"] where await client.isModelDownloaded(model) {
      for (label, punctuation) in [("natural", PunctuationPolicy.natural), ("suppressed", PunctuationPolicy.suppressed)] {
        let engine = EmulatedStreamingEngine(pauseMs: 600, maxBlockSeconds: 12) { block in
          try await client.transcribeSamples(block, model, RequestOptions(language: "de", punctuation: punctuation)).text
        }
        modesReport("\(model)-\(label)", try await deltas(engine, samples))
      }
    }
  }

  /// Freeze each real engine's output, then replay it word by word through
  /// every formatting/lexicon combination. This isolates downstream gains
  /// without changing the model's acoustics between variants. The AI stage
  /// represents an explicit dictation-box action after streaming has ended.
  func testStreamingPipelineAblationsWithOptionalBoxAI() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let packURL = root.appendingPathComponent("dev-docs/06-wortlisten/packs/technical.json")
    let pack = try JSONDecoder().decode(LexiconPack.self, from: Data(contentsOf: packURL))
    var packAliases: [String: String] = [:]
    for entry in pack.entries {
      for alias in entry.aliases { packAliases[LexiconIndex.normalize(alias)] = entry.term }
    }
    let personal: [String: String] = [
      "mycophenolatmophetil": "Mycophenolatmofetil", "mykophenen phenoladmophitil": "Mycophenolatmofetil",
      "ribaroxaban": "Rivaroxaban", "apexaban": "Apixaban",
      "clomerulonephritis": "Glomerulonephritis", "glomerlonifritus": "Glomerulonephritis",
      "urotelkarzinom": "Urothelkarzinom", "urothekarzinom": "Urothelkarzinom",
      "pemprolizumab": "Pembrolizumab", "pembrolyzumab": "Pembrolizumab",
      "iunum": "Jejunum", "junum": "Jejunum",
      "tiniacorpores": "Tinea corporis", "tinia corporis": "Tinea corporis",
      "maskulus vastus lateralis": "Musculus vastus lateralis",
      "st hebungsinfarkt": "ST-Hebungsinfarkt",
    ]
    var allAliases = packAliases
    for (alias, term) in personal { allAliases[alias] = term }
    let report = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/streaming-ablation", isDirectory: true)
    try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
    let llm = LLMHost()
    let aiModel = LLMModelCatalog.preferredInstalledForTests()?.id
    for engineName in ["nemotron-1120ms", "voxtral-4bit", "emulated-parakeet-ultra"] {
      let source = reportDirectory.appendingPathComponent("\(engineName).txt")
      guard let body = try? String(contentsOf: source, encoding: .utf8),
            let boundary = body.range(of: "\n\n") else { throw XCTSkip("Run real streaming engine smoke tests first") }
      let raw = String(body[boundary.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      let deltas = raw.split(whereSeparator: \.isWhitespace).map { String($0) + " " }
      try raw.write(to: report.appendingPathComponent("\(engineName)-asr.txt"), atomically: true, encoding: .utf8)
      for (modeName, mode) in [("normal", StreamingPunctuationMode.automatic),
                               ("literal", .literal), ("normal-commands", .combined)] {
        let stages: [(String, Bool, Bool, [String: String])] = [
          ("base", false, false, [:]),
          ("format", true, true, [:]),
          ("pack", false, false, packAliases),
          ("personal", false, false, personal),
          ("full", true, true, allAliases),
        ]
        for (stage, numbers, code, aliases) in stages {
          var settings = StreamingSettings()
          settings.punctuationMode = mode
          settings.literalScope = .extended
          settings.formatNumbers = numbers
          settings.codeFormatting = code
          settings.lexiconCorrection = !aliases.isEmpty
          var processor = StreamingTextProcessor(options: .init(
            settings: settings, language: "de", englishCommands: true, aliases: aliases
          ))
          var output = ""
          for delta in deltas { output += processor.push(delta) }
          output += processor.flush()
          output = output.trimmingCharacters(in: .whitespacesAndNewlines)
          let label = "\(engineName)-\(modeName)-\(stage)"
          try output.write(to: report.appendingPathComponent("\(label).txt"), atomically: true, encoding: .utf8)
          XCTAssertFalse(output.isEmpty)
          print("STREAM_ABLATION case=\(engineName)-\(modeName) stage=\(stage) chars=\(output.count)")
          guard stage == "full", let aiModel else { continue }
          let outcome = await llm.polish(PolishRequest(
            text: output, style: AIStyleCatalog.clean, modelID: aiModel, settings: PostProcessingSettings(),
            protectedTerms: Array(Set(personal.values)).filter { output.localizedCaseInsensitiveContains($0) }
          ), keepAIResultOnIssues: true, onText: nil)
          try outcome.text.write(to: report.appendingPathComponent("\(engineName)-\(modeName)-full-box-ai.txt"), atomically: true, encoding: .utf8)
          try ("failed=\(outcome.failed) issues=\(outcome.issues)\n")
            .write(to: report.appendingPathComponent("\(engineName)-\(modeName)-full-box-ai-meta.txt"), atomically: true, encoding: .utf8)
          print("STREAM_ABLATION case=\(engineName)-\(modeName) stage=full-box-ai changed=\(outcome.text != output) failed=\(outcome.failed) issues=\(outcome.issues.count)")
        }
      }
    }
    await llm.unload()
  }

  func testNativeStreamingModelUnloadsAfterConfiguredIdleTime() async throws {
    guard NemotronStreamingEngine.isInstalled(chunkMs: 1120) else { throw XCTSkip("Nemotron not installed") }
    let host = StreamingEngineHost()
    await host.sessionStarted()
    let engine = try await host.nemotronEngine(chunkMs: 1120)
    try await engine.begin(language: "de")
    _ = try await engine.feed(Array(repeating: 0, count: 16_000))
    _ = try await engine.end()
    await host.sessionFinished(idleMinutes: 1)
    try await Task.sleep(for: .seconds(65))
    do {
      try await engine.begin(language: "de")
      XCTFail("Idle policy left the native streaming model loaded")
    } catch {
      // The held engine reference exists, but its Core ML manager was freed.
    }
    await host.unloadAll()
  }
}
