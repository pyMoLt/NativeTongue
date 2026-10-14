import XCTest

@testable import Hex

final class KeyEventMonitorClientTests: XCTestCase {
  func testRegisteringFirstHandlerWhenInputMonitoringIsDeniedDoesNotReenterQueue() {
    let monitor = KeyEventMonitorClientLive(
      accessibilityTrustProvider: { false },
      accessibilityTrustPrompt: { false },
      inputMonitoringTrustProvider: { false }
    )

    let token = monitor.handleKeyEvent { _ in false }

    XCTAssertTrue(monitor.readState { true })
    token.cancel()
  }

  /// Audit L10: no 2 s wake-ups in idle once permissions are granted.
  func testPermissionWatchdogSlowsDownOnceGranted() {
    XCTAssertEqual(KeyEventMonitorClientLive.trustCheckInterval(accessibility: true, input: true), .seconds(30))
    XCTAssertEqual(KeyEventMonitorClientLive.trustCheckInterval(accessibility: false, input: true), .seconds(2))
    XCTAssertEqual(KeyEventMonitorClientLive.trustCheckInterval(accessibility: true, input: false), .seconds(2))
  }
}
