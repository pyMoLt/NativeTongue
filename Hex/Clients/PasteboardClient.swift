import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Sauce
import SwiftUI

private let pasteboardLogger = HexLog.pasteboard

/// Text for the dictation box: plain text always, RTF when the box format is Rich Text.
struct RichPastePayload: Equatable, Sendable {
    var plain: String
    var rtf: Data?
    /// App that was frontmost when the box opened; activated before ⌘V.
    var targetBundleID: String?
}

@DependencyClient
struct PasteboardClient {
    var paste: @Sendable (String) async -> Void
    var pasteRich: @Sendable (RichPastePayload) async -> Void
    var copy: @Sendable (String) async -> Void
    /// Copy for a moment only (streaming fallback): clipboard managers are asked
    /// not to keep it (transient/concealed markers).
    var copyTransient: @Sendable (String) async -> Void
    var sendKeyboardCommand: @Sendable (KeyboardCommand) async -> Void
}

extension PasteboardClient: DependencyKey {
    static var liveValue: Self {
        let live = PasteboardClientLive()
        return .init(
            paste: { text in
                await live.paste(text: text)
            },
            pasteRich: { payload in
                await live.pasteRich(payload)
            },
            copy: { text in
                await live.copy(text: text)
            },
            copyTransient: { text in
                await live.copy(text: text, transient: true)
            },
            sendKeyboardCommand: { command in
                await live.sendKeyboardCommand(command)
            }
        )
    }
}

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

struct PasteboardClientLive {
    @Shared(.hexSettings) var hexSettings: HexSettings
    
    struct PasteboardSnapshot {
        enum Value {
            case data(Data)
            case string(String)
            case propertyList(Any)
        }

        let items: [[String: Value]]
        
        init(pasteboard: NSPasteboard) {
            var saved: [[String: Value]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var itemDict: [String: Value] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        itemDict[type.rawValue] = .data(data)
                    } else if let string = item.string(forType: type) {
                        itemDict[type.rawValue] = .string(string)
                    } else if let propertyList = item.propertyList(forType: type) {
                        itemDict[type.rawValue] = .propertyList(propertyList)
                    }
                }
                saved.append(itemDict)
            }
            self.items = saved
        }
        
        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            var restoredItems: [NSPasteboardItem] = []
            for itemDict in items {
                let item = NSPasteboardItem()
                for (type, value) in itemDict {
                    switch value {
                    case let .data(data):
                        item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                    case let .string(string):
                        item.setString(string, forType: NSPasteboard.PasteboardType(rawValue: type))
                    case let .propertyList(propertyList):
                        item.setPropertyList(propertyList, forType: NSPasteboard.PasteboardType(rawValue: type))
                    }
                }
                restoredItems.append(item)
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    @MainActor
    func paste(text: String) async {
        if hexSettings.useClipboardPaste {
            await pasteWithClipboard(text)
        } else {
            LiveTyper.type(text, method: .keyboard)
        }
    }
    
    @MainActor
    func copy(text: String, transient: Bool = false) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([Self.dictationItem(plain: text, transient: transient)])
    }

    /// nspasteboard.org markers: clipboard managers (Paste, Raycast, Alfred …)
    /// skip such items, so temporary dictations stay out of their history (audit M7).
    static let transientMarkerTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    ]

    static func dictationItem(plain: String, rtf: Data? = nil, transient: Bool) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let rtf { item.setData(rtf, forType: .rtf) }
        item.setString(plain, forType: .string)
        if transient {
            for type in transientMarkerTypes { item.setData(Data(), forType: type) }
        }
        return item
    }
    
    @MainActor
    func sendKeyboardCommand(_ command: KeyboardCommand) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // Convert modifiers to CGEventFlags and key codes for modifier keys
        var modifierKeyCodes: [CGKeyCode] = []
        var flags = CGEventFlags()
        
        for modifier in command.modifiers.sorted {
            switch modifier.kind {
            case .command:
                flags.insert(.maskCommand)
                modifierKeyCodes.append(55) // Left Cmd
            case .shift:
                flags.insert(.maskShift)
                modifierKeyCodes.append(56) // Left Shift
            case .option:
                flags.insert(.maskAlternate)
                modifierKeyCodes.append(58) // Left Option
            case .control:
                flags.insert(.maskControl)
                modifierKeyCodes.append(59) // Left Control
            case .fn:
                flags.insert(.maskSecondaryFn)
                // Fn key doesn't need explicit key down/up
            }
        }
        
        // Press modifiers down
        for keyCode in modifierKeyCodes {
            let modDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            modDown?.post(tap: .cghidEventTap)
        }
        
        // Press main key if present
        if let key = command.key {
            let keyCode = Sauce.shared.keyCode(for: key)
            
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            keyDown?.flags = flags
            keyDown?.post(tap: .cghidEventTap)
            
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            keyUp?.flags = flags
            keyUp?.post(tap: .cghidEventTap)
        }
        
        // Release modifiers in reverse order
        for keyCode in modifierKeyCodes.reversed() {
            let modUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            modUp?.post(tap: .cghidEventTap)
        }
        
        pasteboardLogger.debug("Sent keyboard command: \(command.displayName)")
    }

    /// Pastes current clipboard content to the frontmost application
    static func pasteToFrontmostApp() -> Bool {
        let script = """
        if application "System Events" is not running then
            tell application "System Events" to launch
            delay 0.1
        end if
        tell application "System Events"
            tell process (name of first application process whose frontmost is true)
                tell (menu item "Paste" of menu of menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        log (get properties of it)
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    end if
                end tell
                tell (menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    else
                        return false
                    end if
                end tell
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            if let error = error {
                pasteboardLogger.error("AppleScript paste failed: \(error)")
                return false
            }
            return result.booleanValue
        }
        return false
    }

    /// Activates the target app, writes RTF + plain text, sends ⌘V and restores
    /// the previous clipboard exactly like the plain path (plan 5.9).
    @MainActor
    func pasteRich(_ payload: RichPastePayload) async {
        if let bundleID = payload.targetBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
            let deadline = ContinuousClock.now + .milliseconds(800)
            while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        // Kept on purpose only when the user asked to keep dictations on the clipboard.
        pasteboard.writeObjects([Self.dictationItem(plain: payload.plain, rtf: payload.rtf, transient: !hexSettings.copyToClipboard)])
        _ = await waitForPasteboardCommit(targetChangeCount: max(pasteboard.changeCount, before + 1))
        let dictationChangeCount = pasteboard.changeCount
        let pasteSucceeded = await performPaste(payload.plain)
        guard !hexSettings.copyToClipboard else { return }
        await Self.scheduleRestore(snapshot, dictationChangeCount: dictationChangeCount, pasteSucceeded: pasteSucceeded)
    }

    @MainActor
    func pasteWithClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let targetChangeCount = writeAndTrackChangeCount(pasteboard: pasteboard, text: text)
        _ = await waitForPasteboardCommit(targetChangeCount: targetChangeCount)
        let dictationChangeCount = pasteboard.changeCount
        let pasteSucceeded = await performPaste(text)
        
        if !hexSettings.copyToClipboard {
            await Self.scheduleRestore(snapshot, dictationChangeCount: dictationChangeCount, pasteSucceeded: pasteSucceeded)
        }
        
        // If we failed to paste AND user doesn't want clipboard retention,
        // show a notification that text is available in clipboard
        if !pasteSucceeded && !hexSettings.copyToClipboard {
            // Keep the transcribed text in clipboard regardless of setting
            pasteboardLogger.notice("Paste operation failed; text remains in clipboard as fallback.")
            
            // TODO: Could add a notification here to inform user
            // that text is available in clipboard
        }
    }

    /// Success: wait 300 ms for the target app to read the text, then restore.
    /// Failure: leave the text on the clipboard for manual ⌘V for 10 s, restoring
    /// in the background so the dictation flow is not blocked.
    @MainActor
    static func scheduleRestore(_ snapshot: PasteboardSnapshot, dictationChangeCount: Int, pasteSucceeded: Bool) async {
        func restore() {
            let pasteboard = NSPasteboard.general
            // Do not overwrite a new clipboard value copied by the user or target app.
            guard shouldRestoreSnapshot(currentChangeCount: pasteboard.changeCount, dictationChangeCount: dictationChangeCount) else { return }
            snapshot.restore(to: pasteboard)
        }
        if pasteSucceeded {
            try? await Task.sleep(for: .milliseconds(300))
            restore()
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                restore()
            }
        }
    }

    static func shouldRestoreSnapshot(currentChangeCount: Int, dictationChangeCount: Int) -> Bool {
        currentChangeCount == dictationChangeCount
    }

    @MainActor
    private func writeAndTrackChangeCount(pasteboard: NSPasteboard, text: String) -> Int {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.writeObjects([Self.dictationItem(plain: text, transient: !hexSettings.copyToClipboard)])
        let after = pasteboard.changeCount
        if after == before {
            // Ensure we always advance by at least one to avoid infinite waits if the system
            // coalesces writes (seen on Sonoma betas with zero-length strings).
            return after + 1
        }
        return after
    }

    @MainActor
    private func waitForPasteboardCommit(
        targetChangeCount: Int,
        timeout: Duration = .milliseconds(150),
        pollInterval: Duration = .milliseconds(5)
    ) async -> Bool {
        guard targetChangeCount > NSPasteboard.general.changeCount else { return true }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if NSPasteboard.general.changeCount >= targetChangeCount {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    // MARK: - Paste Orchestration

    @MainActor
    private enum PasteStrategy: CaseIterable {
        case cmdV
        case menuItem
        case accessibility
    }

    @MainActor
    private func performPaste(_ text: String) async -> Bool {
        for strategy in PasteStrategy.allCases {
            if await attemptPaste(text, using: strategy) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func attemptPaste(_ text: String, using strategy: PasteStrategy) async -> Bool {
        switch strategy {
        case .cmdV:
            return await postCmdV(delayMs: 0)
        case .menuItem:
            return PasteboardClientLive.pasteToFrontmostApp()
        case .accessibility:
            return (try? Self.insertTextAtCursor(text)) != nil
        }
    }

    // MARK: - Helpers

    @MainActor
    private func postCmdV(delayMs: Int) async -> Bool {
        // Optional tiny wait before keystrokes
        try? await wait(milliseconds: delayMs)
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = vKeyCode()
        let cmdKey: CGKeyCode = 55
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    private func vKeyCode() -> CGKeyCode {
        if Thread.isMainThread { return Sauce.shared.keyCode(for: .v) }
        return DispatchQueue.main.sync { Sauce.shared.keyCode(for: .v) }
    }

    @MainActor
    private func wait(milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
    
    enum PasteError: Error {
        case systemWideElementCreationFailed
        case focusedElementNotFound
        case elementDoesNotSupportTextEditing
        case failedToInsertText
    }
    
    static func insertTextAtCursor(_ text: String) throws {
        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()
        
        // Get the focused element
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        
        guard axError == .success, let focusedElementRef = focusedElementRef else {
            throw PasteError.focusedElementNotFound
        }
        
        let focusedElement = focusedElementRef as! AXUIElement
        
        // Verify if the focused element supports text insertion
        var value: CFTypeRef?
        let supportsText = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &value) == .success
        let supportsSelectedText = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &value) == .success
        
        if !supportsText && !supportsSelectedText {
            throw PasteError.elementDoesNotSupportTextEditing
        }

        // Insert text at cursor position by replacing selected text (or empty selection)
        let insertResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        
        if insertResult != .success {
            throw PasteError.failedToInsertText
        }
    }
}
