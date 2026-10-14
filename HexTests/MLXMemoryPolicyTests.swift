import Qwen3ASR
import XCTest

@testable import Hex

/// Engines must not lift the app-wide MLX cache limit (audit M12).
final class MLXMemoryPolicyTests: XCTestCase {
  func testEnginesCannotRaiseTheAppCacheLimit() {
    MLXMemoryPolicy.apply()
    MLXMemoryControl.capCacheLimit(1 << 30)
    XCTAssertEqual(MLXMemoryControl.cacheLimit, MLXMemoryPolicy.cacheLimitBytes)
    MLXMemoryControl.capCacheLimit(256 * 1_024 * 1_024)
    XCTAssertEqual(MLXMemoryControl.cacheLimit, 256 * 1_024 * 1_024)
    MLXMemoryPolicy.apply()
  }
}
