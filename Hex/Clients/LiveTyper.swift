import AppKit
import ApplicationServices
import Foundation
import HexCore

/// Types streamed text at the cursor of the frontmost app (plan 2.5, 2.1):
/// Unicode keyboard events or Accessibility insertion, never the clipboard.
enum LiveTyper {
  /// Marks NativeTongue's own key events so the hotkey tap ignores them.
  static let eventMarker: Int64 = 0x4E54_5459 // "NTTY"

  @MainActor
  static func type(_ text: String, method: StreamingInsertionMethod) {
    guard !text.isEmpty else { return }
    if method == .accessibility, insertWithAccessibility(text) { return }
    typeWithKeyEvents(text)
  }

  /// Up to `count` characters before the cursor of the focused text field, if
  /// the app exposes them via Accessibility.
  @MainActor
  static func textBeforeCursor(count: Int = 2) -> String? {
    guard let element = focusedElement() else { return nil }
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
    else { return nil }
    var selection = CFRange()
    guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }
    let start = max(selection.location - count, 0)
    var query = CFRange(location: start, length: selection.location - start)
    guard query.length > 0 else { return "" }
    guard let queryValue = AXValueCreate(.cfRange, &query) else { return nil }
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, queryValue, &result) == .success else {
      return nil
    }
    return result as? String
  }

  /// The focused UI element, to tell later whether the same field still has the focus.
  @MainActor
  static func focusedTextElement() -> AXUIElement? {
    focusedElement()
  }

  /// Presses Delete (backspace) `count` times; used only for text NativeTongue typed itself.
  @MainActor
  static func deleteBackward(_ count: Int) {
    guard count > 0 else { return }
    let source = CGEventSource(stateID: .privateState)
    for _ in 0..<count { postKey(51, source: source) }
  }

  // MARK: - Private

  @MainActor
  private static func focusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    return (focused as! AXUIElement)
  }

  @MainActor
  private static func insertWithAccessibility(_ text: String) -> Bool {
    guard let element = focusedElement() else { return false }
    return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
  }

  /// Line breaks become Return presses; other text goes out in chunks of at
  /// most 20 UTF-16 units (the per-event limit of `keyboardSetUnicodeString`).
  @MainActor
  private static func typeWithKeyEvents(_ text: String) {
    let source = CGEventSource(stateID: .privateState)
    for (index, line) in text.components(separatedBy: "\n").enumerated() {
      if index > 0 { postKey(36, source: source) } // Return
      for chunk in unicodeChunks(line) {
        for keyDown in [true, false] {
          guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
          event.flags = []
          event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
          chunk.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
          }
          event.post(tap: .cghidEventTap)
        }
      }
    }
  }

  /// UTF-16 chunks of at most `limit` units that never split a character
  /// (emoji, combining marks; audit L3). A single longer character is sent alone.
  static func unicodeChunks(_ text: String, limit: Int = 20) -> [[UInt16]] {
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []
    for character in text {
      let units = Array(String(character).utf16)
      if !current.isEmpty, current.count + units.count > limit {
        chunks.append(current)
        current = []
      }
      current += units
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  @MainActor
  private static func postKey(_ keyCode: CGKeyCode, source: CGEventSource?) {
    for keyDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
      event.flags = []
      event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
      event.post(tap: .cghidEventTap)
    }
  }
}
