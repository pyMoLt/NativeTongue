import Foundation
import HexCore
import LocalLLM
import XCTest

@testable import Hex

/// Benchmark of the curated language models for AI post-processing, both
/// modes ("Clean up" and "Rewrite as task"), in production order:
/// deterministic pipeline → prompt → sanitizer → safety check.
///
/// Runs only with `LOCAL_ASR_LLM_BENCH=1` (via `TEST_RUNNER_LOCAL_ASR_LLM_BENCH`).
/// Models are taken from the app's model folder and from the benchmark folder
/// (`bench-models/llm`); `LOCAL_ASR_LLM_BENCH_DOWNLOAD=id,id` downloads missing
/// catalog models into the benchmark folder first (never into the app).
/// Writes `/private/tmp/LocalASR-LLM/benchmark.md`.
final class PolishBenchmarkTests: XCTestCase {
  struct Case {
    let name: String
    let input: String
    let mustContain: [String]
    let mustNotContain: [String]
    var needsList = false
  }

  /// One or two cases per further built-in style (C1 acceptance).
  static let styleCases: [(AIStyle, [Case])] = [
    (AIStyleCatalog.builtIn(id: AIStyleCatalog.cleanSentencesID)!, [
      Case(name: "sentences", input: "ähm also wir haben heute die messung gemacht und die messung die war ok äh der druck war bei 120 zu 80 und nicht höher",
           mustContain: ["120", "80", "nicht"], mustNotContain: ["ähm", "äh "]),
    ]),
    (AIStyleCatalog.builtIn(id: AIStyleCatalog.keyFactsID)!, [
      Case(name: "facts", input: "in der besprechung haben wir beschlossen dass das release am 3. november kommt herr schmidt macht die tests und das budget bleibt bei 20000 euro nicht mehr",
           mustContain: ["- ", "3. November|03.11", "Schmidt", "20"], mustNotContain: [], needsList: true),
    ]),
    (AIStyleCatalog.builtIn(id: AIStyleCatalog.emailID)!, [
      Case(name: "email", input: "hallo herr berger ich schicke ihnen den bericht bis freitag ich brauche dafür noch die zahlen vom oktober danke",
           mustContain: ["Berger", "Freitag", "Oktober", "Grüß|Gruß|Danke", "brauche"], mustNotContain: ["Subject", "Betreff", "Brauchen Sie"]),
    ]),
    (AIStyleCatalog.builtIn(id: AIStyleCatalog.messageID)!, [
      Case(name: "message", input: "sag mal kommst du heute abend um sieben zum essen ich reserviere sonst nicht",
           mustContain: ["19|sieben|7", "nicht"], mustNotContain: ["Sehr geehrte", "Mit freundlichen"]),
    ]),
    (AIStyleCatalog.builtIn(id: AIStyleCatalog.noteID)!, [
      Case(name: "note", input: "einkauf für samstag milch eier und zwei kilo mehl und nicht vergessen die geburtstagskarte für oma",
           mustContain: ["Milch", "Eier", "2 kg|zwei Kilo|2 Kilo", "Geburtstagskarte"], mustNotContain: [], needsList: true),
    ]),
  ]

  static let rewriteCases: [Case] = [
    Case(name: "steps", input: "also ich muss morgen äh zuerst die laborwerte von frau müller anschauen dann den arztbrief für herrn schmidt fertig machen und nicht vergessen die überweisung zur kardiologie raus zu schicken",
         mustContain: ["Müller", "Schmidt", "Kardiologie", "Laborwerte", "Arztbrief"], mustNotContain: ["äh"], needsList: true),
    Case(name: "self-correction", input: "wir treffen uns am dienstag nein warte am mittwoch um 14 uhr im besprechungsraum drei",
         mustContain: ["Mittwoch", "14"], mustNotContain: ["Dienstag"]),
    Case(name: "doses-negations", input: "bitte die dosis von metoprolol auf 47,5 mg erhöhen aber ramipril nicht verändern und kein ibuprofen mehr geben",
         mustContain: ["Metoprolol", "47,5 mg", "Ramipril", "nicht", "Ibuprofen"], mustNotContain: [], needsList: true),
    Case(name: "dev-steps", input: "in der datei content view punkt swift den button umbenennen und danach die tests laufen lassen und dann den pull request aufmachen",
         mustContain: ["Button", "Test", "Pull Request"], mustNotContain: [], needsList: true),
    Case(name: "not-answered", input: "ich muss rausfinden wie man in swift ui einen timer baut der jede sekunde aktualisiert",
         mustContain: ["Timer", "Sekunde"], mustNotContain: ["Timer.publish", "```", "import SwiftUI"]),
    Case(name: "english", input: "okay so first update the readme then bump the version to 2.5.1 and finally push the tag",
         mustContain: ["README", "2.5.1", "tag"], mustNotContain: ["zuerst", "dann", "aktualisier"], needsList: true),
    Case(name: "no-letter", input: "schreib der praxis dass ich den termin am freitag um 9 uhr absagen muss",
         mustContain: ["Praxis", "Freitag", "9"], mustNotContain: ["Sehr geehrte", "Liebe", "Mit freundlichen"]),
    Case(name: "rambling", input: "ähm ja also das backup das backup muss eben jeden abend um 22 uhr laufen und die alten backups die älter als 30 tage sind sollen gelöscht werden aber nicht die vom monatsende",
         mustContain: ["22", "30 Tage", "nicht|außer|ausgenommen", "Monatsende"], mustNotContain: ["ähm"]),
  ]

  struct Score {
    var model = ""
    var loadSeconds = 0.0
    var peakMB = 0.0
    var clean = (ok: 0, total: 0, seconds: 0.0, guardHits: 0)
    var rewrite = (ok: 0, total: 0, seconds: 0.0, guardHits: 0)
    /// E-mail, message, note, key facts, clean sentences.
    var otherOK = 0
    var otherTotal = 0
  }

  static var appDirectory: URL { LLMHost.baseDirectory }
  static var benchDirectory: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/com.localasr.LocalASR/bench-models/llm", isDirectory: true)
  }

  private func installedDirectory(_ model: LLMModelDescriptor) -> URL? {
    for base in [Self.appDirectory, Self.benchDirectory]
    where LLMModelInstaller.isInstalled(repository: model.repository, baseDirectory: base) {
      return LLMModelInstaller.localDirectory(repository: model.repository, baseDirectory: base)
    }
    return nil
  }

  func testBenchmarkInstalledModels() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["LOCAL_ASR_LLM_BENCH"] != nil else { throw XCTSkip("Set LOCAL_ASR_LLM_BENCH=1") }
    let settings = PostProcessingSettings()
    let catalog = LLMModelCatalog.all(settings: settings)

    if let wanted = env["LOCAL_ASR_LLM_BENCH_DOWNLOAD"]?.split(separator: ",").map(String.init) {
      for model in catalog where wanted.contains(model.id) && installedDirectory(model) == nil {
        print("Downloading \(model.id) …")
        _ = try await LLMModelInstaller.download(
          repository: model.repository, revision: model.revision, baseDirectory: Self.benchDirectory, progress: { _ in })
      }
    }
    let only = env["LOCAL_ASR_LLM_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

    let reportURL = URL(fileURLWithPath: "/private/tmp/LocalASR-LLM/benchmark.md")
    try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var details = ""
    var scores: [Score] = []

    for model in catalog where only?.contains(model.id) ?? true {
      guard let directory = installedDirectory(model) else { continue }
      let engine = LocalLLMEngine()
      MLXMemoryInfo.resetPeak()
      let loadStart = Date()
      do {
        try await engine.load(directory: directory)
      } catch {
        details += "## \(model.displayName)\n\nLOAD FAILED: \(error.localizedDescription)\n\n"
        continue
      }
      var score = Score(model: model.displayName, loadSeconds: Date().timeIntervalSince(loadStart))
      // Warm-up so the first case does not carry compile time.
      _ = try? await engine.generate(system: "Reply with OK.", user: "Hi", maxTokens: 4)
      details += "## \(model.displayName) (`\(model.id)`)\n"

      for (style, cases) in [(AIStyleCatalog.clean, PolishQualityTests.cases.map { Case(name: $0.name, input: $0.input, mustContain: $0.mustContain, mustNotContain: $0.mustNotContain) }),
                             (AIStyleCatalog.task, Self.rewriteCases)] + Self.styleCases {
        let isClean = style.id == AIStyleCatalog.cleanID
        details += "\n### \(style.name)\n"
        var ok = 0
        var seconds = 0.0
        var guardHits = 0
        for item in cases {
          let tokens = DictationTextPipeline.process(item.input, options: .init(mode: .normal, language: "de"))
          let piped = Assembler.render(tokens, options: AssemblerOptions(language: "de", mode: .normal))
          let start = Date()
          let raw = (try? await engine.generate(
            system: PolishPrompt.system(for: style, settings: settings),
            user: PolishPrompt.user(piped),
            maxTokens: PolishPrompt.maxTokens(for: piped, factor: style.outputFactor),
            stopSequences: PolishOutputSanitizer.generationStopSequences
          )) ?? ""
          let elapsed = Date().timeIntervalSince(start)
          seconds += elapsed
          let text = PolishOutputSanitizer.clean(raw, input: piped)
          let issues = PolishGuard.check(original: piped, result: text, strictness: style.strictness,
                                         lengthTolerancePercent: style.lengthTolerancePercent)
          if !issues.isEmpty { guardHits += 1 }
          let compare: (String) -> Bool = { isClean ? text.contains($0) : text.localizedCaseInsensitiveContains($0) }
          let missing = item.mustContain.filter { option in !option.split(separator: "|").contains { compare(String($0)) } }
          let unwanted = item.mustNotContain.filter { text.localizedCaseInsensitiveContains($0) }
          let listMissing = item.needsList && !text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") || $0.trimmingCharacters(in: .whitespaces).first?.isNumber == true }
          let passed = missing.isEmpty && unwanted.isEmpty && !listMissing && !text.isEmpty
          if passed { ok += 1 }
          details += "\n[\(passed ? "OK" : "FAIL")] \(item.name) (\(String(format: "%.1f", elapsed)) s)\nPIPE: \(piped)\nOUT:\n\(text)\n"
          if !issues.isEmpty { details += "GUARD → original: \(issues.map(\.kind.rawValue))\n" }
          if !missing.isEmpty { details += "missing: \(missing)\n" }
          if !unwanted.isEmpty { details += "unwanted: \(unwanted)\n" }
          if listMissing { details += "no list\n" }
        }
        if isClean {
          score.clean = (ok, cases.count, seconds, guardHits)
        } else if style.id == AIStyleCatalog.taskID {
          score.rewrite = (ok, cases.count, seconds, guardHits)
        } else {
          score.otherOK += ok
          score.otherTotal += cases.count
        }
      }
      score.peakMB = MLXMemoryInfo.peakMegabytes
      scores.append(score)
      details += "\n"
      await engine.unload()
      try writeReport(scores: scores, details: details, to: reportURL)
    }
    guard !scores.isEmpty else { throw XCTSkip("No language model installed") }
    try writeReport(scores: scores, details: details, to: reportURL)
  }

  /// C4: the same dictations with and without reference context. Context must
  /// never appear in the output; quality must not drop.
  func testContextDoesNotLeakAndKeepsQuality() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["LOCAL_ASR_LLM_BENCH"] != nil else { throw XCTSkip("Set LOCAL_ASR_LLM_BENCH=1") }
    let settings = PostProcessingSettings()
    guard let model = LLMModelCatalog.all(settings: settings).first(where: { $0.id == (env["LOCAL_ASR_LLM_CONTEXT_MODEL"] ?? "qwen35-4b-4bit") }),
          let directory = installedDirectory(model) else { throw XCTSkip("Model not installed") }
    let engine = LocalLLMEngine()
    try await engine.load(directory: directory)
    let context = AIContext(
      appName: "Mail",
      profileName: "Mail",
      textBeforeCursor: "Sehr geehrte Frau Dr. Meier,\n\nvielen Dank für Ihre Nachricht zum Projekt Aurora. Wir"
    )
    var analyzed = ContextSettings()
    analyzed.use = .analyzed
    let hints = ContextAnalyzer.analyze(context, isGeneralWord: { SystemWordChecker.shared.isValidWord($0, language: $1) })
    var withText = analyzed
    withText.sendNearbyText = true
    let hintPrompt = ContextAnalyzer.prompt(hints, context: context, settings: analyzed)
    let rawPrompt = ContextAnalyzer.prompt(hints, context: context, settings: withText)
    var report = "# Context probe (\(model.displayName))\n\nHints: \(hintPrompt ?? "-")\n\n| Case | without | hints | hints + text | leak |\n|---|---|---|---|---|\n"
    var okWithout = 0, okWith = 0, okRaw = 0, leaks = 0
    for item in PolishQualityTests.cases {
      let tokens = DictationTextPipeline.process(item.input, options: .init(mode: .normal, language: "de"))
      let piped = Assembler.render(tokens, options: AssemblerOptions(language: "de", mode: .normal))
      var results: [String] = []
      for prompt in [nil, hintPrompt, rawPrompt] {
        let raw = (try? await engine.generate(
          system: PolishPrompt.system(for: AIStyleCatalog.clean, settings: settings, context: prompt),
          user: PolishPrompt.user(piped),
          maxTokens: PolishPrompt.maxTokens(for: piped, factor: AIStyleCatalog.clean.outputFactor),
          stopSequences: PolishOutputSanitizer.generationStopSequences
        )) ?? ""
        results.append(PolishOutputSanitizer.clean(raw, input: piped))
      }
      func passes(_ text: String) -> Bool {
        item.mustContain.allSatisfy { text.contains($0) } && !item.mustNotContain.contains { text.localizedCaseInsensitiveContains($0) }
      }
      let leak = ["Aurora", "Meier", "Sehr geehrte", "Mail", "Nachricht"].filter { word in
        results.dropFirst().contains { $0.contains(word) } && !piped.localizedCaseInsensitiveContains(word)
      }
      if passes(results[0]) { okWithout += 1 }
      if passes(results[1]) { okWith += 1 }
      if passes(results[2]) { okRaw += 1 }
      if !leak.isEmpty { leaks += 1 }
      report += "| \(item.name) | \(passes(results[0]) ? "ok" : "fail") | \(passes(results[1]) ? "ok" : "fail") | \(passes(results[2]) ? "ok" : "fail") | \(leak.joined(separator: ", ")) |\n"
      report += "\n<details><summary>\(item.name)</summary>\n\nwithout: \(results[0])\n\nhints: \(results[1])\n\nhints + text: \(results[2])\n</details>\n\n"
    }
    report += "\n**without \(okWithout)/\(PolishQualityTests.cases.count) · hints \(okWith)/\(PolishQualityTests.cases.count) · hints + text \(okRaw)/\(PolishQualityTests.cases.count) · leaks \(leaks)**\n"
    await engine.unload()
    let url = URL(fileURLWithPath: "/private/tmp/LocalASR-LLM/context.md")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try report.write(to: url, atomically: true, encoding: .utf8)
    XCTAssertEqual(leaks, 0, "context must never appear in the output")
    XCTAssertGreaterThanOrEqual(okWith, okWithout - 1, "context must not make the result clearly worse")
  }

  private func writeReport(scores: [Score], details: String, to url: URL) throws {
    var table = "# AI post-processing benchmark\n\n| Model | Clean | Rewrite | Other styles | Guard hits (C/R) | Ø s Clean | Ø s Rewrite | Load s | Peak MB |\n|---|---|---|---|---|---|---|---|---|\n"
    for s in scores {
      table += "| \(s.model) | \(s.clean.ok)/\(s.clean.total) | \(s.rewrite.ok)/\(s.rewrite.total) | \(s.otherOK)/\(s.otherTotal) | \(s.clean.guardHits)/\(s.rewrite.guardHits) | "
      table += String(format: "%.2f | %.2f | %.1f | %.0f |\n", s.clean.seconds / Double(max(1, s.clean.total)), s.rewrite.seconds / Double(max(1, s.rewrite.total)), s.loadSeconds, s.peakMB)
    }
    try (table + "\n" + details).write(to: url, atomically: true, encoding: .utf8)
  }
}
