import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import LocalLLM

private let llmLogger = HexLog.llm

/// One AI post-processing job.
struct PolishRequest: Sendable {
  var text: String
  /// The AI style (instruction, example, strictness, budget).
  var style: AIStyle
  var modelID: String
  var settings: PostProcessingSettings
  /// Vocabulary terms in the text that must survive (safety check).
  var protectedTerms: [String] = []
  /// Reference context for the model (app name, selection, text before the
  /// cursor). Never edited, never checked, never stored or logged.
  var context: String?
  /// Overrides the style's paragraph splitting (e.g. long files).
  var chunked: Bool?
  /// Overrides `settings.timeoutSeconds` (long files).
  var timeoutSeconds: Int?
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

  private let engine: LocalLLMEngine
  /// Derived from the engine after each load, never assumed (audit M4).
  private(set) var loadedModelID: String?
  private var idleTimer = IdleUnloadTimer()
  /// Preloads and polish jobs in flight; the idle unload waits for them.
  private var activeJobs = 0
  private let idleDelayForTesting: Duration?

  init(engine: LocalLLMEngine = LocalLLMEngine(), idleDelayForTesting: Duration? = nil) {
    self.engine = engine
    self.idleDelayForTesting = idleDelayForTesting
  }

  func preload(modelID: String, settings: PostProcessingSettings) async {
    guard let descriptor = LLMModelCatalog.descriptor(id: modelID, settings: settings),
          LLMModelInstaller.isInstalled(repository: descriptor.repository, baseDirectory: Self.baseDirectory)
    else { return }
    guard loadedModelID != descriptor.id else { return }
    beginJob()
    defer { endJob(settings, afterPreload: true) }
    do {
      try await load(descriptor)
    } catch {
      llmLogger.error("AI model preload failed: \(error.localizedDescription, privacy: .private)")
    }
  }

  func unload() async {
    idleTimer.cancel()
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
    beginJob()
    defer { endJob(request.settings, afterPreload: false) }
    do {
      try await load(descriptor)
      let ai = try await withTimeout(seconds: request.timeoutSeconds ?? request.settings.timeoutSeconds) { [engine] in
        try await Self.generate(request, engine: engine, onText: onText)
      }
      guard !Task.isCancelled else { return fallback }
      let issues = request.settings.guardEnabled
        ? PolishGuard.check(
          original: original,
          result: ai,
          strictness: request.style.strictness,
          lengthTolerancePercent: request.style.lengthTolerancePercent,
          protectedTerms: request.protectedTerms
        )
        : []
      llmLogger.notice("AI post-processing finished; style=\(request.style.isBuiltIn ? request.style.id : "custom") issues=\(issues.count)")
      let useAI = issues.isEmpty || keepAIResultOnIssues
      return PolishOutcome(text: useAI ? ai : original, original: original, aiText: ai, issues: issues, failed: false)
    } catch {
      llmLogger.error("AI post-processing failed: \(error.localizedDescription, privacy: .private)")
      return fallback
    }
  }

  private static func generate(_ request: PolishRequest, engine: LocalLLMEngine, onText: (@Sendable (String) -> Void)?) async throws -> String {
    let system = PolishPrompt.system(for: request.style, settings: request.settings, context: request.context)
    let factor = request.style.outputFactor
    let split = (request.chunked ?? request.style.chunked)
      ? PolishChunker.split(request.text)
      : PolishChunker.Split(chunks: [request.text], separators: [""])
    let separators = split.separators
    var done: [String] = []
    for part in split.chunks {
      let prefix = PolishChunker.join(done, separators: separators)
      let raw = try await engine.generate(
        system: system,
        user: PolishPrompt.user(part),
        maxTokens: PolishPrompt.maxTokens(for: part, factor: factor),
        stopSequences: PolishOutputSanitizer.generationStopSequences
      ) { partial in
        let current = PolishOutputSanitizer.clean(partial, input: part)
        onText?(prefix.isEmpty ? current : PolishChunker.join(done + [current], separators: separators))
      }
      try Task.checkCancellation()
      done.append(PolishOutputSanitizer.clean(raw, input: part))
    }
    return PolishChunker.join(done, separators: separators)
  }

  private func load(_ descriptor: LLMModelDescriptor) async throws {
    let directory = LLMModelInstaller.localDirectory(repository: descriptor.repository, baseDirectory: Self.baseDirectory)
    guard LLMModelInstaller.isInstalled(repository: descriptor.repository, baseDirectory: Self.baseDirectory) else {
      throw PolishFailure.modelNotInstalled
    }
    if loadedModelID != descriptor.id { await engine.unload() }
    try await engine.load(directory: directory)
    // Another call may have unloaded the engine while it was loading.
    loadedModelID = await engine.loadedDirectory == directory ? descriptor.id : nil
    guard loadedModelID != nil else { throw LocalLLMError.notLoaded }
  }

  private func beginJob() {
    activeJobs += 1
    idleTimer.cancel()
  }

  /// Applies the memory policy once no job is left. A hotkey preload stays
  /// for the imminent dictation: "after each task" applies after generation.
  private func endJob(_ settings: PostProcessingSettings, afterPreload: Bool) {
    activeJobs = max(0, activeJobs - 1)
    guard activeJobs == 0 else { return }
    let delay: Duration
    switch settings.unloadPolicy {
    case .never:
      return
    case .afterEachTask:
      if afterPreload { return }
      delay = .zero
    case .afterIdle:
      delay = idleDelayForTesting ?? .seconds(max(settings.idleUnloadMinutes, 1) * 60)
    }
    idleTimer.schedule(after: delay) { [weak self] generation in
      await self?.unloadIfIdle(generation: generation)
    }
  }

  private func unloadIfIdle(generation: UInt64) async {
    guard idleTimer.isCurrent(generation), activeJobs == 0 else { return }
    idleTimer.detach()
    await engine.unload()
    loadedModelID = nil
  }

  /// Test hook: the model the host believes is loaded.
  func currentModelID() -> String? { loadedModelID }
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
