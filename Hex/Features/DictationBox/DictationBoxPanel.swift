import AppKit
import ComposableArchitecture
import SwiftUI

/// Floating, typeable panel for the dictation box. Opens without stealing
/// focus from the target app; becomes key when the user clicks into it.
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
    minSize = NSSize(width: 480, height: 260)
    let hosting = NSHostingView(rootView: content)
    contentView = hosting
    title = "Diktierbox"
    setAccessibilityTitle("Diktierbox")
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

  init(store: StoreOf<AppFeature>) {
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .presentDictationBox, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.show(store: store) }
    })
    observers.append(center.addObserver(forName: .dismissDictationBox, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
    })
  }

  private func show(store: StoreOf<AppFeature>) {
    if panel == nil {
      panel = DictationBoxPanel(content: DictationBoxView(
        store: store.scope(state: \.dictationBox, action: \.dictationBox),
        transcription: store.scope(state: \.transcription, action: \.transcription)
      ))
    }
    panel?.orderFrontRegardless()
  }
}
