import AppKit
import Foundation
import XCTest

@testable import Hex

@MainActor
final class PasteboardSnapshotTests: XCTestCase {
  func testSnapshotRestoresAllItemsAndRepresentations() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("LocalASR.PasteboardSnapshotTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    let textItem = NSPasteboardItem()
    textItem.setString("previous text", forType: .string)

    let dataType = NSPasteboard.PasteboardType("com.localasr.test-binary")
    let dataItem = NSPasteboardItem()
    let payload = Data([0x00, 0x2A, 0xFF])
    dataItem.setData(payload, forType: dataType)

    XCTAssertTrue(pasteboard.writeObjects([textItem, dataItem]))
    let snapshot = PasteboardClientLive.PasteboardSnapshot(pasteboard: pasteboard)

    pasteboard.clearContents()
    pasteboard.setString("temporary dictated text", forType: .string)
    snapshot.restore(to: pasteboard)

    let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(restoredItems.count, 2)
    XCTAssertEqual(restoredItems[0].string(forType: .string), "previous text")
    XCTAssertEqual(restoredItems[1].data(forType: dataType), payload)
  }

  func testSnapshotRestoreGuardPreservesNewClipboardChanges() {
    XCTAssertTrue(PasteboardClientLive.shouldRestoreSnapshot(currentChangeCount: 12, dictationChangeCount: 12))
    XCTAssertFalse(PasteboardClientLive.shouldRestoreSnapshot(currentChangeCount: 13, dictationChangeCount: 12))
  }

  func testTemporaryDictationIsMarkedTransientAndConcealed() {
    let item = PasteboardClientLive.dictationItem(plain: "Diktat", transient: true)
    XCTAssertEqual(item.string(forType: .string), "Diktat")
    for type in PasteboardClientLive.transientMarkerTypes {
      XCTAssertTrue(item.types.contains(type), type.rawValue)
    }
    let kept = PasteboardClientLive.dictationItem(plain: "Diktat", transient: false)
    XCTAssertFalse(kept.types.contains(PasteboardClientLive.transientMarkerTypes[0]))
  }
}
