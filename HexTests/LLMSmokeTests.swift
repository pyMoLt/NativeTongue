import Foundation
import HexCore
import LocalLLM
import XCTest
@testable import Hex

/// Runs a real local language model when one is available. Uses
/// `LOCAL_ASR_LLM_DIR`, `/private/tmp/LocalASR-LLM/dir` (a file containing a
/// path) or an LM Studio copy of Qwen3.5 4B; skipped otherwise.
final class LLMSmokeTests: XCTestCase {
  private func modelDirectory() throws -> URL {
    let candidates = [
      ProcessInfo.processInfo.environment["LOCAL_ASR_LLM_DIR"],
      (try? String(contentsOfFile: "/private/tmp/LocalASR-LLM/dir", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
      NSHomeDirectory() + "/.lmstudio/models/mlx-community/Qwen3.5-4B-MLX-4bit",
    ].compactMap { $0 }
    for path in candidates where FileManager.default.fileExists(atPath: path + "/config.json") {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    throw XCTSkip("No local MLX language model available")
  }

  func testCleanModeKeepsDoseAndFixesSpelling() async throws {
    let directory = try modelDirectory()
    let engine = LocalLLMEngine()
    let loadStart = Date()
    try await engine.load(directory: directory)
    let loadSeconds = Date().timeIntervalSince(loadStart)

    let input = "ähm der patient bekommt 2,5 mg rivaroxaban einmal täglich die kontrolle erfolgt in zwei wochen bitte schreibe groß a b c"
    let settings = PostProcessingSettings()
    let start = Date()
    let raw = try await engine.generate(
      system: PolishPrompt.system(for: .clean, settings: settings),
      user: PolishPrompt.user(input),
      maxTokens: PolishPrompt.maxTokens(for: input, factor: settings.cleanMaxOutputFactor),
      stopSequences: PolishOutputSanitizer.generationStopSequences
    )
    let seconds = Date().timeIntervalSince(start)
    let output = PolishOutputSanitizer.clean(raw, input: input)
    let issues = PolishGuard.check(original: input, result: output, strictness: .strict, lengthTolerancePercent: 25)
    let report = "model \(directory.lastPathComponent)\nload \(String(format: "%.1f", loadSeconds)) s, generate \(String(format: "%.1f", seconds)) s\nissues: \(issues.map(\.kind.rawValue))\noutput: \(output)\n"
    let reportDir = URL(fileURLWithPath: "/private/tmp/LocalASR-LLM", isDirectory: true)
    try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
    try? report.write(to: reportDir.appendingPathComponent("last-smoke.txt"), atomically: true, encoding: .utf8)

    XCTAssertFalse(output.isEmpty)
    XCTAssertTrue(output.contains("2,5 mg"), output)
    XCTAssertTrue(output.contains("Rivaroxaban"), output)
    XCTAssertFalse(output.contains("<think>"))
    await engine.unload()
  }

  func testCleanModeDistinguishesSpokenCommandsFromLiteralWords() async throws {
    let engine = LocalLLMEngine()
    try await engine.load(directory: modelDirectory())
    let input = "Befund Doppelpunkt keine Blutung Klammer auf links Klammer zu Punkt Das Wort Klammer steht im Bericht und soll als Wort stehen bleiben. Keine Änderung der Dosis von 2,5 mg Apixaban."
    let settings = PostProcessingSettings()
    let raw = try await engine.generate(
      system: PolishPrompt.system(for: .clean, settings: settings),
      user: PolishPrompt.user(input),
      maxTokens: PolishPrompt.maxTokens(for: input, factor: settings.cleanMaxOutputFactor),
      stopSequences: PolishOutputSanitizer.generationStopSequences
    )
    let output = PolishOutputSanitizer.clean(raw, input: input)
    let directory = URL(fileURLWithPath: "/private/tmp/LocalASR-LLM", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try output.write(to: directory.appendingPathComponent("spoken-command-smoke.txt"), atomically: true, encoding: .utf8)
    XCTAssertTrue(output.contains("Befund:"), output)
    XCTAssertTrue(output.contains("(links)"), output)
    XCTAssertTrue(output.contains("Wort Klammer"), output)
    XCTAssertTrue(output.contains("2,5 mg Apixaban"), output)
    XCTAssertTrue(output.contains("Keine Änderung"), output)
    await engine.unload()
  }

  func testInstalledAutomaticModelUsesProductionPolishPipeline() async throws {
    let settings = PostProcessingSettings()
    let modelID = "qwen35-2b-8bit"
    guard let descriptor = LLMModelCatalog.descriptor(id: modelID, settings: settings),
          LLMModelInstaller.isInstalled(repository: descriptor.repository, baseDirectory: LLMHost.baseDirectory)
    else { throw XCTSkip("App's Qwen 2B model is not installed") }
    let host = LLMHost()
    let input = "Befund Doppelpunkt keine Blutung Klammer auf links Klammer zu Punkt Das Wort Klammer steht im Bericht. Keine Änderung der Dosis von 2,5 mg Apixaban."
    let outcome = await host.polish(
      PolishRequest(text: input, mode: .clean, modelID: modelID, settings: settings,
                    protectedTerms: ["Apixaban"]),
      keepAIResultOnIssues: false, onText: nil
    )
    let directory = URL(fileURLWithPath: "/private/tmp/LocalASR-LLM", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try ("output: \(outcome.text)\nAI: \(outcome.aiText ?? "-")\nissues: \(outcome.issues)\n")
      .write(to: directory.appendingPathComponent("app-2b-polish.txt"), atomically: true, encoding: .utf8)
    XCTAssertFalse(outcome.failed, outcome.text)
    XCTAssertTrue(outcome.text.contains("Befund:"), outcome.text)
    XCTAssertTrue(outcome.text.contains("(links)"), outcome.text)
    XCTAssertTrue(outcome.text.contains("Wort Klammer"), outcome.text)
    XCTAssertTrue(outcome.text.contains("2,5 mg Apixaban"), outcome.text)
    XCTAssertTrue(outcome.text.contains("Keine Änderung"), outcome.text)
    await host.unload()
  }

  func testConciseDefaultPreservesEverydayTextAndCodeSwitching() async throws {
    let settings = PostProcessingSettings()
    let modelID = "qwen35-2b-8bit"
    guard let descriptor = LLMModelCatalog.descriptor(id: modelID, settings: settings),
          LLMModelInstaller.isInstalled(repository: descriptor.repository, baseDirectory: LLMHost.baseDirectory)
    else { throw XCTSkip("App's Qwen 2B model is not installed") }
    let host = LLMHost()
    let ordinary = "ähm morgen treffen wir uns um 10 Uhr im Café am Bahnhof. Danach gehen wir in die Bibliothek und sprechen über das Buch. Bitte erinnere mich an die rote Mappe."
    let everyday = await host.polish(PolishRequest(text: ordinary, mode: .clean, modelID: modelID,
      settings: settings), keepAIResultOnIssues: false, onText: nil)
    let report = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003", isDirectory: true)
    try everyday.text.write(to: report.appendingPathComponent("concise-prompt-everyday.txt"), atomically: true, encoding: .utf8)
    XCTAssertFalse(everyday.failed)
    XCTAssertTrue(everyday.issues.isEmpty, "\(everyday.issues)")
    for fact in ["10 Uhr", "Café", "Bibliothek", "Buch", "rote Mappe"] {
      XCTAssertTrue(everyday.text.localizedCaseInsensitiveContains(fact), everyday.text)
    }
    let source = report.appendingPathComponent("ablation/terminology-normal-full.txt")
    guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Run real batch ablation first") }
    let mixed = try String(contentsOf: source, encoding: .utf8)
    let outcome = await host.polish(PolishRequest(text: mixed, mode: .clean, modelID: modelID,
      settings: settings, protectedTerms: ["Mycophenolatmofetil", "Rivaroxaban"]),
      keepAIResultOnIssues: false, onText: nil)
    try outcome.text.write(to: report.appendingPathComponent("concise-prompt-mixed.txt"), atomically: true, encoding: .utf8)
    XCTAssertFalse(outcome.failed)
    XCTAssertTrue(outcome.issues.isEmpty, "\(outcome.issues)")
    XCTAssertTrue((outcome.aiText ?? "").contains("The surrounding sentence remains German"), outcome.aiText ?? "-")
    await host.unload()
  }

  func testCodeSwitchingPromptVariantsOnRealTranscript() async throws {
    let path = "/private/tmp/NativeTongue-QA-20261003/ablation/terminology-normal-full.txt"
    guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Run real batch ablation first") }
    let input = try String(contentsOfFile: path, encoding: .utf8)
    let reminder = """

    Critical clean-up rule: preserve every complete sentence in its original order, even if it comments on language or spelling. An English sentence inside German dictation is dictated content. Keep it in English; never treat it as a redundant instruction about the text.
    """
    let example = """

    Example input: Die App nutzt MLX. The next sentence is in English and should keep its normal spelling. Danach folgt wieder Deutsch.
    Example output: Die App nutzt MLX. The next sentence is in English and should keep its normal spelling. Danach folgt wieder Deutsch.
    """
    let host = LLMHost()
    let directory = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/prompt-variants", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, extra) in [("reminder", reminder), ("reminder-example", reminder + example)] {
      var settings = PostProcessingSettings()
      settings.customCleanPrompt = PolishPrompt.defaultClean + extra
      let outcome = await host.polish(PolishRequest(
        text: input, mode: .clean, modelID: "qwen35-2b-8bit", settings: settings,
        protectedTerms: ["Mycophenolatmofetil", "Rivaroxaban"]
      ), keepAIResultOnIssues: true, onText: nil)
      try (outcome.aiText ?? "<failed>").write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
      try ("failed=\(outcome.failed) issues=\(outcome.issues)\n")
        .write(to: directory.appendingPathComponent("\(name)-meta.txt"), atomically: true, encoding: .utf8)
      print("PROMPT_VARIANT \(name) englishSentence=\((outcome.aiText ?? "").contains("The surrounding sentence remains German")) issues=\(outcome.issues.count)")
    }
    await host.unload()
  }

  func testSpokenCommandPromptVariantsOnRealNormalTranscript() async throws {
    let path = "/private/tmp/NativeTongue-QA-20261003/ablation/commands-normal-parakeet-full.txt"
    guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Run Parakeet normal ablation first") }
    let input = try String(contentsOfFile: path, encoding: .utf8)
    let reminder = """

    Review every remaining spoken punctuation word before replying. If the speaker meant formatting, replace the entire word or phrase with its mark and remove nearby ASR punctuation echoes: "Punkt" → ., "Doppelpunkt" → :, "Semikolon" → ;, "Klammer auf" → (, "Klammer zu" → ), "Bindestrich" → -, "Fragezeichen" → ?, "Neuer Absatz" → a blank line, "Neue Zeile" → a line break. A previous ASR period or comma beside a formatting command is not a reason to leave the command as a word. Preserve literal discussion such as "das Wort Klammer".
    """
    let example = """

    Example input: Bericht. Punkt. Neuer Absatz. Befund Doppelpunkt stabil, sonst gut Punkt. Neue Zeile, Hinweis Klammer auf, links Bindestrich rechts, Klammer zu, Fragezeichen.
    Example output: Bericht.

    Befund: stabil, sonst gut.
    Hinweis (links-rechts)?
    """
    let host = LLMHost()
    let directory = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/command-prompt-variants", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, extra) in [("reminder", reminder), ("reminder-example", reminder + example)] {
      var settings = PostProcessingSettings()
      settings.customCleanPrompt = PolishPrompt.defaultClean + extra
      let outcome = await host.polish(PolishRequest(text: input, mode: .clean,
        modelID: "qwen35-2b-8bit", settings: settings), keepAIResultOnIssues: true, onText: nil)
      try (outcome.aiText ?? "<failed>").write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
      try ("failed=\(outcome.failed) issues=\(outcome.issues)\n")
        .write(to: directory.appendingPathComponent("\(name)-meta.txt"), atomically: true, encoding: .utf8)
    }
    await host.unload()
  }

  func testExistingCommandRendererOnNoisyNormalTranscript() throws {
    let path = "/private/tmp/NativeTongue-QA-20261003/ablation/commands-normal-parakeet-full.txt"
    guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Run Parakeet normal ablation first") }
    let input = try String(contentsOfFile: path, encoding: .utf8)
    var processor = StreamingTextProcessor(options: .init(keepPunctuation: true, commands: .all))
    let output = processor.push(input + " ") + processor.flush()
    let directory = URL(fileURLWithPath: "/private/tmp/NativeTongue-QA-20261003/command-prompt-variants", isDirectory: true)
    try output.write(to: directory.appendingPathComponent("deterministic-renderer.txt"), atomically: true, encoding: .utf8)
    var negative = StreamingTextProcessor(options: .init(keepPunctuation: true, commands: .all))
    let literal = negative.push("Das Wort Doppelpunkt soll hier als Wort stehen bleiben. ") + negative.flush()
    try literal.write(to: directory.appendingPathComponent("deterministic-literal-control.txt"), atomically: true, encoding: .utf8)
  }
}
