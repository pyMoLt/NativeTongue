import XCTest

@testable import Hex

/// Key events carry at most 20 UTF-16 units; characters must stay whole (audit L3).
final class LiveTyperTests: XCTestCase {
  func testChunksNeverSplitCharacters() {
    let text = String(repeating: "a", count: 19) + "👍🏽" + "e\u{301}" + String(repeating: "ß", count: 25) + "🇩🇪"
    let chunks = LiveTyper.unicodeChunks(text)
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
    XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
    for chunk in chunks {
      XCTAssertNotNil(String(utf16CodeUnits: chunk, count: chunk.count).unicodeScalars.first)
      XCTAssertEqual(String(decoding: chunk, as: UTF16.self).utf16.count, chunk.count, "no broken surrogate pair")
    }
    XCTAssertEqual(String(decoding: chunks[0], as: UTF16.self), String(repeating: "a", count: 19))
  }
}
