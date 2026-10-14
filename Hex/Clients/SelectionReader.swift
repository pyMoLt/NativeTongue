import AppKit
import ApplicationServices
import Foundation

/// Reads the selected text of the frontmost app for Command Mode (C3).
/// Accessibility first; if the app does not expose its selection, ⌘C with the
/// clipboard restored right after. The text is never stored or logged.
enum SelectionReader {
  static func selectedText() async -> String? {
    if let text = await MainActor.run(body: { accessibilitySelection() }), !text.isEmpty {
      return text
    }
    return await copySelection()
  }

  /// Selected text via Accessibility only (no ⌘C), for the AI context.
  @MainActor
  static func accessibilitySelectionText() -> String? {
    accessibilitySelection()
  }

  @MainActor
  private static func accessibilitySelection() -> String? {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    var selected: CFTypeRef?
    guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else {
      return nil
    }
    return (selected as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? selected as? String : nil
  }

  /// ⌘C into the clipboard, read, then put the previous clipboard back.
  private static func copySelection() async -> String? {
    let (snapshot, changeCount) = await MainActor.run { () -> ([NSPasteboardItem], Int) in
      let pasteboard = NSPasteboard.general
      let copies = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in item.types {
          if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
      }
      let before = pasteboard.changeCount
      postCommandC()
      return (copies, before)
    }
    try? await Task.sleep(for: .milliseconds(180))
    return await MainActor.run { () -> String? in
      let pasteboard = NSPasteboard.general
      let copied = pasteboard.changeCount != changeCount ? pasteboard.string(forType: .string) : nil
      if pasteboard.changeCount != changeCount {
        pasteboard.clearContents()
        if !snapshot.isEmpty { pasteboard.writeObjects(snapshot) }
      }
      guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return copied
    }
  }

  @MainActor
  private static func postCommandC() {
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: down) else { continue }
      event.flags = .maskCommand
      event.setIntegerValueField(.eventSourceUserData, value: LiveTyper.eventMarker)
      event.post(tap: .cghidEventTap)
    }
  }
}
