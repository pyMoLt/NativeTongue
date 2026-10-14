import HexCore
import LocalLLM
import XCTest

@testable import Hex

/// Idle unload must not hit a model that is in use again (audit M4).
final class IdleUnloadTests: XCTestCase {
  func testCancelInvalidatesATimerThatAlreadyFired() async {
    let owner = TimerOwner()
    await owner.scheduleNow()
    await owner.cancelBeforeTheFiredCallRuns()
    try? await Task.sleep(for: .milliseconds(100))
    let unloads = await owner.unloads
    XCTAssertEqual(unloads, 0)

    await owner.scheduleNow()
    try? await Task.sleep(for: .milliseconds(100))
    let later = await owner.unloads
    XCTAssertEqual(later, 1)
  }

  /// Second ✨ right after the first with "unload after each task": the unload
  /// of the first job must not pull the model away from the second.
  func testBackToBackPolishWithUnloadAfterEachTask() async throws {
    var settings = PostProcessingSettings()
    settings.unloadPolicy = .afterEachTask
    let modelID = "qwen35-2b-8bit"
    guard let descriptor = LLMModelCatalog.descriptor(id: modelID, settings: settings),
          LLMModelInstaller.isInstalled(repository: descriptor.repository, baseDirectory: LLMHost.baseDirectory)
    else { throw XCTSkip("Qwen 2B is not installed") }
    let host = LLMHost()
    let request = PolishRequest(text: "das ist ein kurzer test ohne punkt", style: AIStyleCatalog.clean, modelID: modelID, settings: settings)
    async let first = host.polish(request, keepAIResultOnIssues: true, onText: nil)
    try await Task.sleep(for: .milliseconds(20))
    async let second = host.polish(request, keepAIResultOnIssues: true, onText: nil)
    let results = await [first, second]
    XCTAssertFalse(results[0].failed)
    XCTAssertFalse(results[1].failed)
    let third = await host.polish(request, keepAIResultOnIssues: true, onText: nil)
    XCTAssertFalse(third.failed)
    try await Task.sleep(for: .milliseconds(300))
    let loaded = await host.currentModelID()
    XCTAssertNil(loaded, "after the last task the model is unloaded")
  }
}

private actor TimerOwner {
  private var timer = IdleUnloadTimer()
  private(set) var unloads = 0

  func scheduleNow() {
    timer.schedule(after: .zero) { [weak self] generation in
      await self?.fired(generation)
    }
  }

  /// Bumps the generation; the already started timer still calls `fired`.
  func cancelBeforeTheFiredCallRuns() { timer.cancel() }

  private func fired(_ generation: UInt64) {
    guard timer.isCurrent(generation) else { return }
    timer.detach()
    unloads += 1
  }
}
