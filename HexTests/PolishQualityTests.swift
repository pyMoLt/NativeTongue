import Foundation
import HexCore
import LocalLLM
import XCTest

@testable import Hex

/// Quality probe for AI post-processing ("Bereinigen") on realistic dictation
/// snippets through the production LLMHost (Qwen 2B, automatic) and a 4B box
/// model if present. Writes a report; asserts only the must-have cases.
final class PolishQualityTests: XCTestCase {
  struct Case {
    let name: String
    let input: String
    let mustContain: [String]
    let mustNotContain: [String]
  }

  static let cases: [Case] = [
    Case(name: "spelling", input: "der code lautet bitte schreibe groß a b c und dann weiter", mustContain: ["ABC", "Code", "weiter"], mustNotContain: ["groß A B C", "schreibe groß"]),
    Case(name: "spelling-alphabet", input: "der wirkstoff heißt a wie anton p wie paula i wie ida x wie xanthippe a wie anton b wie berta a wie anton n wie nordpol", mustContain: ["APIXABAN", "Wirkstoff"], mustNotContain: ["wie Anton"]),
    Case(name: "commands", input: "Befund Doppelpunkt kein Erguss Klammer auf rechts Klammer zu Punkt neuer Absatz Beurteilung Doppelpunkt unauffällig Punkt", mustContain: ["Befund:", "(rechts)", "Beurteilung:"], mustNotContain: ["Klammer auf", "Doppelpunkt"]),
    Case(name: "literal-word", input: "In diesem Satz geht es um das Wort Doppelpunkt und um die Klammer als Zeichen.", mustContain: ["Wort Doppelpunkt", "Klammer"], mustNotContain: []),
    Case(name: "grammar", input: "der patient hat gestern zwei tablette genommen und er fühlen sich besser", mustContain: ["Tabletten", "fühlt"], mustNotContain: []),
    Case(name: "misheard-term", input: "die dosis von ribaroxaban bleibt bei 20 mg", mustContain: ["Rivaroxaban", "20 mg"], mustNotContain: []),
    Case(name: "negation", input: "es gibt keinen hinweis auf eine thrombose und keine blutung", mustContain: ["keinen Hinweis", "keine Blutung"], mustNotContain: []),
    Case(name: "question-kept", input: "kannst du mir sagen wie spät es ist", mustContain: ["?"], mustNotContain: ["Uhr"]),
    Case(name: "english-commands", input: "please refactor the content view komma then run the tests punkt", mustContain: ["refactor", "tests."], mustNotContain: ["komma", "punkt"]),
    Case(name: "everyday", input: "ähm also morgen treffen wir uns um 10 uhr am bahnhof und äh danach gehen wir essen", mustContain: ["10 Uhr", "Bahnhof", "essen"], mustNotContain: ["ähm", "äh "]),
  ]

  private func run(label: String, polish: (String) async -> (text: String, issues: [PolishGuardIssue])) async -> (report: String, failures: [String]) {
    var report = "## \(label)\n"
    var failures: [String] = []
    for item in Self.cases {
      // Production order: deterministic pipeline (Normal mode) first, then AI.
      let tokens = DictationTextPipeline.process(item.input, options: .init(mode: .normal, language: "de"))
      let piped = Assembler.render(tokens, options: AssemblerOptions(language: "de", mode: .normal))
      let start = Date()
      let (text, issues) = await polish(piped)
      let seconds = Date().timeIntervalSince(start)
      let missing = item.mustContain.filter { !text.contains($0) }
      let present = item.mustNotContain.filter { text.localizedCaseInsensitiveContains($0) }
      let ok = missing.isEmpty && present.isEmpty
      if !ok { failures.append(item.name) }
      report += "\n[\(ok ? "OK" : "FAIL")] \(item.name) (\(String(format: "%.1f", seconds)) s)\nIN:  \(item.input)\nPIPE: \(piped)\nOUT: \(text)\n"
      if !issues.isEmpty { report += "GUARD: \(issues.map(\.kind.rawValue))\n" }
      if !missing.isEmpty { report += "missing: \(missing)\n" }
      if !present.isEmpty { report += "unwanted: \(present)\n" }
    }
    report += "\n\(Self.cases.count - failures.count)/\(Self.cases.count) OK\n\n"
    return (report, failures)
  }

  func testCleanQualityOnInstalledModels() async throws {
    var settings = PostProcessingSettings()
    settings.guardEnabled = true
    var report = ""
    var ranAny = false

    if let descriptor = LLMModelCatalog.descriptor(id: "qwen35-2b-8bit", settings: settings),
       LLMModelInstaller.isInstalled(repository: descriptor.repository, baseDirectory: LLMHost.baseDirectory) {
      ranAny = true
      let host = LLMHost()
      let result = await run(label: "Qwen3.5 2B 8-bit (automatic, production host, keep AI result)") { input in
        let outcome = await host.polish(PolishRequest(text: input, style: AIStyleCatalog.clean, modelID: descriptor.id, settings: settings), keepAIResultOnIssues: true, onText: nil)
        return (outcome.aiText ?? "(failed) " + outcome.text, outcome.issues)
      }
      report += result.report
      await host.unload()
    }

    let fourB = URL(fileURLWithPath: NSHomeDirectory() + "/.lmstudio/models/mlx-community/Qwen3.5-4B-MLX-4bit")
    if FileManager.default.fileExists(atPath: fourB.appendingPathComponent("config.json").path) {
      ranAny = true
      let engine = LocalLLMEngine()
      try await engine.load(directory: fourB)
      let result = await run(label: "Qwen3.5 4B 4-bit (box)") { input in
        let raw = (try? await engine.generate(
          system: PolishPrompt.system(for: AIStyleCatalog.clean, settings: settings),
          user: PolishPrompt.user(input),
          maxTokens: PolishPrompt.maxTokens(for: input, factor: AIStyleCatalog.clean.outputFactor),
          stopSequences: PolishOutputSanitizer.generationStopSequences
        )) ?? ""
        let text = PolishOutputSanitizer.clean(raw, input: input)
        return (text, PolishGuard.check(original: input, result: text, strictness: .strict, lengthTolerancePercent: 25))
      }
      report += result.report
      await engine.unload()
    }
    guard ranAny else { throw XCTSkip("No local language model installed") }
    let dir = URL(fileURLWithPath: "/private/tmp/LocalASR-LLM", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try report.write(to: dir.appendingPathComponent("quality.md"), atomically: true, encoding: .utf8)
  }
}
