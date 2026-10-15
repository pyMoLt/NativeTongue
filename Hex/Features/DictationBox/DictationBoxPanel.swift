import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

/// Floating, typeable panel for the dictation box. Recording leaves the target
/// app focused; after transcription the editor becomes the active typing target.
/// Escape and the window close button never discard the dictation.
final class DictationBoxPanel: NSPanel {
  init(content: some View) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
      styleMask: [.titled, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    level = .floating
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    // The content's minimum size (style, scale, text size) limits resizing, so
    // controls are never cut off at the edges.
    minSize = NSSize(width: 300, height: 120)
    let hosting = NSHostingView(rootView: content)
    hosting.sizingOptions = [.minSize]
    contentView = hosting
    title = "Dictation Box"
    setAccessibilityTitle("Dictation Box")
    if !setFrameUsingName("LocalASRDictationBox") {
      placeAboveDock()
    }
    setFrameAutosaveName("LocalASRDictationBox")
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_ sender: Any?) {}
  override func performClose(_ sender: Any?) {}

  /// Default position: bottom centre of the screen with the mouse, above the Dock.
  func placeAboveDock() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let size = frame.size
    setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
  }
}

/// Shows/hides the panel on the box notifications.
@MainActor
final class DictationBoxPanelController {
  private var panel: DictationBoxPanel?
  private var observers: [NSObjectProtocol] = []

  private let store: StoreOf<AppFeature>

  private var look: DictationBoxAppearance { store.dictationBox.hexSettings.appearance.dictationBox }

  init(store: StoreOf<AppFeature>) {
    self.store = store
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .presentDictationBox, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.show(store: store) }
    })
    observers.append(center.addObserver(forName: .dismissDictationBox, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
    })
    observers.append(center.addObserver(forName: .focusDictationBox, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.focusEditor() }
    })
    observers.append(center.addObserver(forName: .resetDictationBoxPosition, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let panel = self.panel else { return }
        let size = DictationBoxMetrics.defaultSize(self.look.style)
        let scale = self.look.clampedScale
        panel.setContentSize(NSSize(width: size.width * scale, height: size.height * scale))
        panel.placeAboveDock()
      }
    })
    observers.append(center.addObserver(forName: .dictationBoxLookChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.updateOpacity()
        self?.updateWindowAppearance()
      }
    })
    // Less in the way while another app is active; opaque while you work in the box.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self, let panel = self.panel, note.object as? NSWindow === panel else { return }
          self.updateOpacity()
        }
      })
    }
  }

  /// Own light/dark mode of the box (Appearance → Dictation Box → own look).
  private func updateWindowAppearance() {
    guard let panel else { return }
    let appearance = look.ownColorScheme?.boxWindowAppearance
    if panel.appearance?.name != appearance?.name { panel.appearance = appearance }
  }

  private func updateOpacity() {
    guard let panel else { return }
    let target = panel.isKeyWindow ? 1 : CGFloat(look.clampedInactiveOpacity)
    if panel.alphaValue != target { panel.animator().alphaValue = target }
  }

  private func show(store: StoreOf<AppFeature>) {
    if panel == nil {
      panel = DictationBoxPanel(content: DictationBoxView(
        store: store.scope(state: \.dictationBox, action: \.dictationBox),
        transcription: store.scope(state: \.transcription, action: \.transcription)
      ))
    }
    updateWindowAppearance()
    panel?.orderFrontRegardless()
    updateOpacity()
  }

  private func focusEditor() {
    guard let panel else { return }
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    if let editor = findEditor(in: panel.contentView) {
      panel.makeFirstResponder(editor)
    }
  }

  private func findEditor(in view: NSView?) -> BoxTextView? {
    guard let view else { return nil }
    if let editor = view as? BoxTextView { return editor }
    for child in view.subviews {
      if let editor = findEditor(in: child) { return editor }
    }
    return nil
  }
}
