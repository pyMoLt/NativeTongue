import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

/// NSTextView subclass with word hover detection (400 ms) and number-key
/// selection while the suggestion popover is visible.
final class BoxTextView: NSTextView {
  var onHover: ((NSRange) -> Void)?
  var onChooseSuggestion: ((Int) -> Bool)?
  var onEscape: (() -> Void)?
  private var hoverWork: DispatchWorkItem?
  private var trackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    hoverWork?.cancel()
    let screenPoint = NSEvent.mouseLocation
    let work = DispatchWorkItem { [weak self] in self?.reportHover(at: screenPoint) }
    hoverWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    hoverWork?.cancel()
  }

  private func reportHover(at screenPoint: NSPoint) {
    guard selectedRange().length == 0 else { return }
    let index = characterIndex(for: screenPoint)
    guard index != NSNotFound, index < (string as NSString).length,
          let range = BoxTextEditing.wordRange(at: index, in: string)
    else { return }
    let rect = firstRect(forCharacterRange: range, actualRange: nil)
    guard rect.insetBy(dx: -2, dy: -3).contains(screenPoint) else { return }
    onHover?(range)
  }

  override func keyDown(with event: NSEvent) {
    if let characters = event.charactersIgnoringModifiers, characters.count == 1,
       let digit = Int(characters), (1...5).contains(digit), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
       onChooseSuggestion?(digit - 1) == true {
      return
    }
    super.keyDown(with: event)
  }

  /// Escape never discards the box; it only closes the suggestion popover.
  override func cancelOperation(_ sender: Any?) {
    onEscape?()
  }

  /// View-local rect of a character range (for anchoring the popover).
  func rect(for range: NSRange) -> NSRect? {
    guard let window else { return nil }
    let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
    guard screenRect != .zero else { return nil }
    let windowRect = window.convertFromScreen(screenRect)
    return convert(windowRect, from: nil)
  }
}

struct BoxTextEditor: NSViewRepresentable {
  let store: StoreOf<DictationBoxFeature>
  /// Minimal style with an own text colour: drawn on top, never stored in the text.
  var displayTextColor: NSColor?
  /// Box scale (Appearance): zooms the text display only; the inserted text keeps its size.
  var scale: Double = 1

  func makeCoordinator() -> Coordinator { Coordinator(store: store) }

  private func applyScale(_ scrollView: NSScrollView) {
    let magnification = CGFloat(min(max(scale, 0.8), 1.5))
    guard scrollView.magnification != magnification else { return }
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 0.8
    scrollView.maxMagnification = 1.5
    scrollView.magnification = magnification
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = BoxTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    let textView = BoxTextView(frame: scrollView.contentView.bounds)
    textView.autoresizingMask = [.width]
    textView.isRichText = true
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 14, height: 12)
    textView.delegate = context.coordinator
    textView.setAccessibilityLabel("Dictation text")
    textView.onHover = { [weak coordinator = context.coordinator] range in coordinator?.hovered(range) }
    textView.onChooseSuggestion = { [weak coordinator = context.coordinator] index in coordinator?.choose(index) ?? false }
    textView.onEscape = { [weak coordinator = context.coordinator] in coordinator?.store.send(.dismissSuggestions) }
    scrollView.documentView = textView
    applyScale(scrollView)
    context.coordinator.textView = textView
    context.coordinator.displayTextColor = displayTextColor
    context.coordinator.apply(store.state)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    applyScale(nsView)
    context.coordinator.displayTextColor = displayTextColor
    context.coordinator.apply(store.state)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
    let store: StoreOf<DictationBoxFeature>
    weak var textView: BoxTextView?
    var displayTextColor: NSColor?
    private var shownTextColor: NSColor?
    private var appliedRevision = -1
    private var isApplying = false
    private var popover: NSPopover?
    private var popoverRange: NSRange?
    /// Pointer tracking for the suggestion popover: enter/exit events instead
    /// of a 20 Hz polling timer (audit L9).
    private var trackingAreas: [(view: NSView, area: NSTrackingArea)] = []
    private var pendingDismissal: DispatchWorkItem?

    init(store: StoreOf<DictationBoxFeature>) {
      self.store = store
    }

    func apply(_ state: DictationBoxFeature.State) {
      guard let textView else { return }
      textView.typingAttributes = BoxTextStyle.attributes(font: state.baseFont)
      if state.revision != appliedRevision {
        appliedRevision = state.revision
        isApplying = true
        textView.textStorage?.setAttributedString(state.text.value)
        textView.setSelectedRange(BoxTextEditing.clamp(state.selection, length: state.text.length))
        textView.scrollRangeToVisible(textView.selectedRange())
        isApplying = false
      }
      applyDisplayColor(force: false)
      updatePopover(state.suggestion)
    }

    /// Own text colour of the Minimal style as a display-only attribute, so the
    /// inserted text keeps its normal colour. TextKit 1 is used only then.
    func applyDisplayColor(force: Bool) {
      guard let textView else { return }
      guard force || displayTextColor != shownTextColor || displayTextColor != nil else { return }
      if let color = displayTextColor, let layout = textView.layoutManager {
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
        textView.insertionPointColor = color
      } else if shownTextColor != nil, let layout = textView.layoutManager {
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        textView.insertionPointColor = .textColor
      }
      shownTextColor = displayTextColor
    }

    func textDidChange(_ notification: Notification) {
      guard !isApplying, let textView, let storage = textView.textStorage else { return }
      store.send(.textEdited(BoxText(storage), selection: textView.selectedRange()))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !isApplying, let textView else { return }
      store.send(.selectionChanged(textView.selectedRange()))
    }

    func hovered(_ range: NSRange) {
      store.send(.wordHovered(range))
    }

    func choose(_ index: Int) -> Bool {
      guard popover?.isShown == true, let suggestions = store.suggestion?.suggestions, index < suggestions.count else { return false }
      store.send(.applySuggestion(suggestions[index].term))
      return true
    }

    private func updatePopover(_ suggestion: DictationBoxFeature.SuggestionState?) {
      guard let suggestion, let textView else {
        stopPointerTracking()
        if popover?.isShown == true { popover?.performClose(nil) }
        popover = nil
        popoverRange = nil
        return
      }
      if popover?.isShown == true, popoverRange == suggestion.range { return }
      popover?.performClose(nil)
      guard let rect = textView.rect(for: suggestion.range) else { return }
      let popover = NSPopover()
      popover.behavior = .semitransient
      popover.animates = false
      popover.delegate = self
      popover.contentViewController = NSHostingController(rootView: SuggestionPopoverView(store: store))
      popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
      self.popover = popover
      popoverRange = suggestion.range
      startPointerTracking(wordRect: rect)
    }

    func popoverDidClose(_ notification: Notification) {
      guard (notification.object as? NSPopover) === popover else { return }
      stopPointerTracking()
      popover = nil
      popoverRange = nil
      if store.suggestion != nil { store.send(.dismissSuggestions) }
    }

    private func startPointerTracking(wordRect: NSRect) {
      stopPointerTracking()
      guard let textView else { return }
      let wordArea = NSTrackingArea(
        rect: wordRect.insetBy(dx: -4, dy: -4),
        options: [.mouseEnteredAndExited, .activeAlways, .assumeInside],
        owner: self
      )
      textView.addTrackingArea(wordArea)
      trackingAreas.append((textView, wordArea))
      if let panel = popover?.contentViewController?.view {
        let panelArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        panel.addTrackingArea(panelArea)
        trackingAreas.append((panel, panelArea))
      }
    }

    private func stopPointerTracking() {
      for (view, area) in trackingAreas { view.removeTrackingArea(area) }
      trackingAreas = []
      pendingDismissal?.cancel()
      pendingDismissal = nil
    }

    @objc func mouseEntered(with event: NSEvent) {
      pendingDismissal?.cancel()
      pendingDismissal = nil
    }

    /// Leaving the word or the panel closes the popover after a short grace
    /// time, unless the pointer arrived in the other one meanwhile.
    @objc func mouseExited(with event: NSEvent) {
      pendingDismissal?.cancel()
      let work = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated { self?.dismissIfPointerLeft() }
      }
      pendingDismissal = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func dismissIfPointerLeft() {
      pendingDismissal = nil
      guard let popover, popover.isShown, let textView, let popoverRange else {
        stopPointerTracking()
        return
      }
      let pointer = NSEvent.mouseLocation
      let wordRect = textView.firstRect(forCharacterRange: popoverRange, actualRange: nil)
        .insetBy(dx: -4, dy: -4)
      let panelRect = popover.contentViewController?.view.window?.frame.insetBy(dx: -4, dy: -4)
      guard !wordRect.contains(pointer), panelRect?.contains(pointer) != true else { return }
      store.send(.dismissSuggestions)
    }
  }
}

/// Top-5 suggestions plus original / re-dictate / spell / lexicon (plan 5.8).
struct SuggestionPopoverView: View {
  let store: StoreOf<DictationBoxFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let suggestion = store.suggestion {
        if suggestion.isLoading {
          ProgressView().controlSize(.small).padding(8)
        } else if suggestion.suggestions.isEmpty {
          Text("No similar terms")
            .flowFont(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        ForEach(Array(suggestion.suggestions.enumerated()), id: \.element.id) { index, item in
          Button {
            store.send(.applySuggestion(item.term))
          } label: {
            HStack(spacing: 8) {
              Text("\(index + 1)")
                .flowFont(.caption, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .frame(width: 12)
              Text(item.term)
                .fontWeight(index == 0 ? .semibold : .regular)
              Spacer(minLength: 12)
              if item.isUser {
                Image(systemName: "person.crop.circle")
                  .flowFont(.caption)
                  .foregroundStyle(.tint)
                  .help("From your vocabulary")
              }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
          }
          .buttonStyle(.plain)
        }
        Divider().padding(.vertical, 1)
        if let original = suggestion.original {
          menuButton("arrow.uturn.backward", "Original: \(original)") { store.send(.revertCorrection) }
        }
        menuButton("mic", "Re-dictate") { store.send(.prepareRedictation) }
        menuButton("character.cursor.ibeam", "Spell") { store.send(.spellSelection) }
        menuButton("text.book.closed", "„\(suggestion.word)“ ins Lexikon") { store.send(.addHoveredWordToLexicon) }
      }
    }
    .padding(4)
    .frame(minWidth: 190, maxWidth: 250)
  }

  private func menuButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .flowFont(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }
    .buttonStyle(.plain)
  }
}
