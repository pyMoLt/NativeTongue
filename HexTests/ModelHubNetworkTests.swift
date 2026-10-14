import Foundation
import XCTest

@testable import Hex

/// The hub opens only for the install and returns to the previous value (audit M9).
final class ModelHubNetworkTests: XCTestCase {
  func testRestoresPreviousValueAfterSuccessAndFailure() async {
    let flag = LockedFlag(true)
    let inside = await ModelHubNetwork.whileInstalling(read: { flag.value }, write: { flag.value = $0 }) { flag.value }
    XCTAssertFalse(inside)
    XCTAssertTrue(flag.value)

    struct Failure: Error {}
    do {
      try await ModelHubNetwork.whileInstalling(read: { flag.value }, write: { flag.value = $0 }) { throw Failure() }
      XCTFail("expected error")
    } catch {}
    XCTAssertTrue(flag.value)

    // A previous "online" state is kept, not forced to offline.
    flag.value = false
    await ModelHubNetwork.whileInstalling(read: { flag.value }, write: { flag.value = $0 }) {}
    XCTAssertFalse(flag.value)
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Bool
  init(_ value: Bool) { stored = value }
  var value: Bool {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
