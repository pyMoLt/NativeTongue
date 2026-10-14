import Foundation
import XCTest

@testable import Hex

/// One model job at a time; later jobs wait instead of failing (audit M3, M10).
final class ModelJobQueueTests: XCTestCase {
  func testSecondJobWaitsInsteadOfFailingBusy() async throws {
    let client = TranscriptionClientLive(idleUnloadDelayForTesting: .seconds(3_600))
    let gate = Gate()
    let order = OrderLog()
    let first = Task { try await client.runJob(background: false) { await gate.wait(); await order.append("first") } }
    await gate.waitUntilWaiting()
    let second = Task { try await client.runJob(background: false) { await order.append("second") } }
    try await Task.sleep(for: .milliseconds(100))
    var log = await order.entries
    XCTAssertEqual(log, [])
    await gate.open()
    try await first.value
    try await second.value
    log = await order.entries
    XCTAssertEqual(log, ["first", "second"])
  }

  func testDictationGoesBeforeWaitingFileJobs() async throws {
    let client = TranscriptionClientLive(idleUnloadDelayForTesting: .seconds(3_600))
    let gate = Gate()
    let order = OrderLog()
    let running = Task { try await client.runJob(background: true) { await gate.wait(); await order.append("file-1") } }
    await gate.waitUntilWaiting()
    let file = Task { try await client.runJob(background: true) { await order.append("file-2") } }
    try await Task.sleep(for: .milliseconds(50))
    let dictation = Task { try await client.runJob(background: false) { await order.append("dictation") } }
    try await Task.sleep(for: .milliseconds(50))
    await gate.open()
    try await running.value
    try await file.value
    try await dictation.value
    let log = await order.entries
    XCTAssertEqual(log, ["file-1", "dictation", "file-2"])
  }

  func testCancelledWaitingJobDoesNotRunAndPassesTheSlotOn() async throws {
    let client = TranscriptionClientLive(idleUnloadDelayForTesting: .seconds(3_600))
    let gate = Gate()
    let order = OrderLog()
    let running = Task { try await client.runJob(background: false) { await gate.wait(); await order.append("first") } }
    await gate.waitUntilWaiting()
    let cancelled = Task { try await client.runJob(background: false) { await order.append("cancelled") } }
    try await Task.sleep(for: .milliseconds(50))
    let next = Task { try await client.runJob(background: false) { await order.append("next") } }
    try await Task.sleep(for: .milliseconds(50))
    cancelled.cancel()
    await gate.open()
    try await running.value
    do {
      try await cancelled.value
      XCTFail("A cancelled job must not run")
    } catch is CancellationError {}
    try await next.value
    let log = await order.entries
    XCTAssertEqual(log, ["first", "next"])
  }

  func testUnloadWaitsForRunningJobInsteadOfSkipping() async throws {
    let client = TranscriptionClientLive(idleUnloadDelayForTesting: .seconds(3_600))
    let gate = Gate()
    let order = OrderLog()
    let running = Task { try await client.runJob(background: false) { await gate.wait(); await order.append("job") } }
    await gate.waitUntilWaiting()
    let unload = Task { await client.unloadModel(); await order.append("unloaded") }
    try await Task.sleep(for: .milliseconds(100))
    var log = await order.entries
    XCTAssertEqual(log, [], "unload must wait, not return as a no-op")
    await gate.open()
    try await running.value
    await unload.value
    log = await order.entries
    XCTAssertEqual(log, ["job", "unloaded"])
  }

  func testStreamingReservationHoldsBatchJobsUntilReleased() async throws {
    let client = TranscriptionClientLive(idleUnloadDelayForTesting: .seconds(3_600))
    let order = OrderLog()
    try await client.reserveForStreaming()
    let batch = Task { try await client.runJob(background: true) { await order.append("file") } }
    try await Task.sleep(for: .milliseconds(100))
    var log = await order.entries
    XCTAssertEqual(log, [])
    await client.releaseForStreaming()
    try await batch.value
    log = await order.entries
    XCTAssertEqual(log, ["file"])
  }
}

private actor Gate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false
  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func waitUntilWaiting() async { while continuation == nil { await Task.yield() } }
  func open() { opened = true; continuation?.resume(); continuation = nil }
}

private actor OrderLog {
  private(set) var entries: [String] = []
  func append(_ entry: String) { entries.append(entry) }
}
