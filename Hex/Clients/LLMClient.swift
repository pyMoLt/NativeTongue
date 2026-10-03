import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import LocalLLM

private let llmLogger = HexLog.llm

/// One AI post-processing job.
struct PolishRequest: Sendable {
  var text: String
  var mode: PolishMode
  var modelID: String
  var settings: PostProcessingSettings
  /// Vocabulary terms in the text that must survive (safety check).
  var protectedTerms: [String] = []
}

/// Result of a job. `text` is what should be used: the AI text, or the
/// original when the safety check (automatic mode) or the model failed.
struct PolishOutcome: Equatable, Sendable {
  var text: String
  var original: String
  var aiText: String?
  var issues: [PolishGuardIssue]
  var failed: Bool

  /// Shown as ⚠︎ in the pill: the AI failed or the safety check found issues.
  var hasWarning: Bool { failed || !issues.isEmpty }
}

enum PolishFailure: Error, LocalizedError {
  case modelNotInstalled
  case timedOut

  var errorDescription: String? {
    switch self {
    case .modelNotInstalled: "The selected AI model is not installed."
    case .timedOut: "The AI model took too long."
    }
  }
}

@DependencyClient
struct LLMClient {
  /// Runs the job. `onText` streams partial output (dictation box).
  /// `keepAIResultOnIssues`: box = true (marks issues), automatic = false (uses original).
  var polish: @Sendable (_ request: PolishRequest, _ keepAIResultOnIssues: Bool, _ onText: (@Sendable (String) -> Void)?) async -> PolishOutcome = { request, _, _ in
    PolishOutcome(text: request.text, original: request.text, aiText: nil, issues: [], failed: true)
  }
  var preload: @Sendable (_ modelID: String, _ settings: PostProcessingSettings) async -> Void = { _, _ in }
  var unload: @Sendable () async -> Void = {}
  var loadedModelID: @Sendable () async -> String? = { nil }
  var isInstalled: @Sendable (_ descriptor: LLMModelDescriptor) -> Bool = { _ in false }
  var install: @Sendable (_ descriptor: LLMModelDescriptor, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
  var remove: @Sendable (_ descriptor: LLMModelDescriptor) async throws -> Void
  var remoteInfo: @Sendable (_ linkOrID: String) async throws -> LLMRemoteInfo
}

extension LLMClient: DependencyKey {
  static var liveValue: Self {
    let host = LLMHost()
    return Self(
      polish: { await host.polish($0, keepAIResultOnIssues: $1, onText: $2) },
      preload: { await host.preload(modelID: $0, settings: $1) },
      unload: { await host.unload() },
      loadedModelID: { await host.loadedModelID },
      isInstalled: { LLMModelInstaller.isInstalled(repository: $0.repository, baseDirectory: LLMHost.baseDirectory) },
      install: { descriptor, progress in
        _ = try await LLMModelInstaller.download(
          repository: descriptor.repository,
          revision: descriptor.revision,
          baseDirectory: LLMHost.baseDirectory,
          progress: progress
        )
      },
      remove: { descriptor in
        await host.unloadIfUsing(modelID: descriptor.id)
        let directory = LLMModelInstaller.localDirectory(repository: descriptor.repository, baseDirectory: LLMHost.baseDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
          try FileManager.default.removeItem(at: directory)
        }
      },
      remoteInfo: { text in
        let repository = try LLMModelInstaller.repositoryID(from: text)
        return try await LLMModelInstaller.remoteInfo(repository: repository)
      }
    )
  }

  /// Inert client for tests and previews: nothing installed, polishing
  /// returns the original text. Tests override what they need.
  static var testValue: Self {
    Self(
      polish: { request, _, _ in PolishOutcome(text: request.text, original: request.text, aiText: nil, issues: [], failed: true) },
      preload: { _, _ in },
      unload: {},
      loadedModelID: { nil },
      isInstalled: { _ in false },
      install: { _, _ in },
      remove: { _ in },
      remoteInfo: { _ in throw PolishFailure.modelNotInstalled }
    )
  }

  static var previewValue: Self { testValue }
}

extension DependencyValues {
  var llm: LLMClient {
    get { self[LLMClient.self] }
    set { self[LLMClient.self] = newValue }
  }
}

/// Owns the loaded language model and its memory policy
/// (after each task / after idle time / keep loaded).
actor LLMHost {
  static var baseDirectory: URL {
    ((try? URL.hexModelsDirectory) ?? URL.hexModelsDirectoryPath).appendingPathComponent("llm", isDirectory: true)
  }

  private let engine = LocalLLMEngine()
  private(set) var loadedModelID: String?
  private var idleTask: Task<Void, Never>?

  func preload(modelID: String, settings: PostProcessingSettings) async {
    guard let descriptor = LLMModelCatalog.descriptor(id: modelID, settings: settings),
          LLMModelInstaller.isInstalled(repository: descriptor.repository, baseDirectory: Self.baseDirectory)
    else { return }
    guard loadedModelID != descriptor.id else { return }
    do {
      try await load(descriptor)
      // Keep a hotkey preload available for the imminent dictation. The
      // after-each-task policy applies after generation, not after preload.
      if settings.unloadPolicy == .afterIdle { scheduleUnload(settings) }
    } catch {
      llmLogger.error("AI model preload failed: \(error.localizedDescription, privacy: .private)")
    }
  }

  func unload() async {
    idleTask?.cancel()
    idleTask = nil
    await engine.unload()
    loadedModelID = nil
  }

  func unloadIfUsing(modelID: String) async {
    guard loadedModelID == modelID else { return }
    await unload()
  }

  func polish(_ request: PolishRequest, keepAIResultOnIssues: Bool, onText: (@Sendable (String) -> Void)?) async -> PolishOutcome {
    let original = request.text
    let fallback = PolishOutcome(text: original, original: original, aiText: nil, issues: [], failed: true)
    // Exactly the model the user selected; a missing or uninstalled model
    // fails visibly (original text, ⚠︎) instead of switching models.
    guard let descriptor = LLMModelCatalog.descriptor(id: request.modelID, settings: request.settings) else { return fallback }
    idleTask?.cancel()
    defer { scheduleUnload(request.settings) }
    do {
      try await load(descriptor)
      let ai = try await withTimeout(seconds: request.settings.timeoutSeconds) { [engine] in
        try await Self.generate(request, engine: engine, onText: onText)
      }
      guard !Task.isCancelled else { return fallback }
      let issues = request.settings.guardEnabled
        ? PolishGuard.check(
          original: original,
          result: ai,
          strictness: request.settings.strictness(for: request.mode),
          lengthTolerancePercent: request.settings.lengthTolerancePercent,
          protectedTerms: request.protectedTerms
        )
        : []
      llmLogger.notice("AI post-processing finished; mode=\(request.mode.rawValue) issues=\(issues.count)")
      let useAI = issues.isEmpty || keepAIResultOnIssues
      return PolishOutcome(text: useAI ? ai : original, original: original, aiText: ai, issues: issues, failed: false)
    } catch {
      llmLogger.error("AI post-processing failed: \(error.localizedDescription, privacy: .private)")
      return fallback
    }
  }

  private static func generate(_ request: PolishRequest, engine: LocalLLMEngine, onText: (@Sendable (String) -> Void)?) async throws -> String {
    let system = PolishPrompt.system(for: request.mode, settings: request.settings)
    let factor = request.settings.maxOutputFactor(for: request.mode)
    let parts = request.mode == .clean ? PolishChunker.chunks(request.text) : [request.text]
    var done: [String] = []
    for part in parts {
      let prefix = PolishChunker.join(done, original: request.text)
      let raw = try await engine.generate(
        system: system,
        user: PolishPrompt.user(part),
        maxTokens: PolishPrompt.maxTokens(for: part, factor: factor),
        stopSequences: PolishOutputSanitizer.generationStopSequences
      ) { partial in
        let current = PolishOutputSanitizer.clean(partial, input: part)
        onText?(prefix.isEmpty ? current : PolishChunker.join([prefix, current], original: request.text))
      }
      try Task.checkCancellation()
      done.append(PolishOutputSanitizer.clean(raw, input: part))
    }
    return PolishChunker.join(done, original: request.text)
  }

  private func load(_ descriptor: LLMModelDescriptor) async throws {
    let directory = LLMModelInstaller.localDirectory(repository: descriptor.repository, baseDirectory: Self.baseDirectory)
    guard LLMModelInstaller.isInstalled(repository: descriptor.repository, baseDirectory: Self.baseDirectory) else {
      throw PolishFailure.modelNotInstalled
    }
    if loadedModelID != descriptor.id { await engine.unload() }
    try await engine.load(directory: directory)
    loadedModelID = descriptor.id
  }

  private func scheduleUnload(_ settings: PostProcessingSettings) {
    idleTask?.cancel()
    switch settings.unloadPolicy {
    case .never:
      idleTask = nil
    case .afterEachTask:
      idleTask = Task { await self.unload() }
    case .afterIdle:
      let minutes = max(settings.idleUnloadMinutes, 1)
      idleTask = Task {
        try? await Task.sleep(for: .seconds(minutes * 60))
        guard !Task.isCancelled else { return }
        await self.unload()
      }
    }
  }
}

/// Runs `operation`, cancelling it after `seconds` (0 = no limit).
private func withTimeout<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
  guard seconds > 0 else { return try await operation() }
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw PolishFailure.timedOut
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}
