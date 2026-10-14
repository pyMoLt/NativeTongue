import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// Result of a correction command spoken after a normal insertion.
enum InsertionEditOutcome: Equatable, Sendable {
  case applied
  /// The app or the text field changed since the insertion: nothing deleted (pill ⚠︎).
  case targetChanged
  /// Nothing NativeTongue inserted is left to edit (or the words were not found).
  case nothingToEdit
}

/// Correction commands („streich das“, „ersetze X durch Y“ …) for the text
/// NativeTongue just inserted into another app. Only acts when the same app
/// and the same text field still have the focus; never deletes more than its
/// own insertion (plan B1).
@DependencyClient
struct InsertionEditorClient {
  /// After a successful insertion: remembers the text and the focused field.
  var remember: @Sendable (_ text: String) async -> Void = { _ in }
  /// Applies the commands to the remembered insertion.
  var apply: @Sendable (_ edits: [EditCommand]) async -> InsertionEditOutcome = { _ in .nothingToEdit }
  /// The remembered insertion (for „ersetze X durch Y“ recognition).
  var lastInsertion: @Sendable () async -> String? = { nil }
}

extension InsertionEditorClient: DependencyKey {
  static var liveValue: Self {
    let live = InsertionEditorLive()
    return Self(
      remember: { text in await live.remember(text) },
      apply: { edits in await live.apply(edits) },
      lastInsertion: { await live.lastInsertion() }
    )
  }

  /// Inert in tests: nothing remembered, nothing edited.
  static var testValue: Self {
    Self(remember: { _ in }, apply: { _ in .nothingToEdit }, lastInsertion: { nil })
  }
}

extension DependencyValues {
  var insertionEditor: InsertionEditorClient {
    get { self[InsertionEditorClient.self] }
    set { self[InsertionEditorClient.self] = newValue }
  }
}

@MainActor
final class InsertionEditorLive {
  nonisolated init() {}

  private struct Insertion {
    var bundleID: String?
    var element: AXUIElement?
    var segments: [String]
  }

  private var insertion: Insertion?

  func remember(_ text: String) {
    guard !text.isEmpty else { return }
    let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let element = LiveTyper.focusedTextElement()
    if var current = insertion, current.bundleID == bundleID, Self.same(current.element, element) {
      // A follow-up dictation into the same field extends the editable insertion.
      current.segments.append(Self.leadingSpaceIfNeeded(text, after: current.segments.joined()))
      insertion = current
    } else {
      insertion = Insertion(bundleID: bundleID, element: element, segments: [text])
    }
  }

  func lastInsertion() -> String? {
    insertion.map { $0.segments.joined() }
  }

  func apply(_ edits: [EditCommand]) async -> InsertionEditOutcome {
    guard var current = insertion else { return .nothingToEdit }
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == current.bundleID,
          Self.same(current.element, LiveTyper.focusedTextElement()),
          Self.fieldStillEndsWith(current.segments.joined(), element: current.element)
    else {
      insertion = nil
      return .targetChanged
    }
    let before = current.segments.joined()
    var changed = false
    for edit in edits {
      guard let next = TextEditPlanner.apply(edit, to: current.segments) else { continue }
      current.segments = next
      changed = true
    }
    guard changed else { return .nothingToEdit }
    let strokes = TextEditPlanner.keystrokes(from: before, to: current.segments.joined())
    LiveTyper.deleteBackward(strokes.delete)
    if !strokes.insert.isEmpty { LiveTyper.type(strokes.insert, method: .keyboard) }
    insertion = current.segments.isEmpty ? nil : current
    return .applied
  }

  // MARK: - Helpers

  private static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case let (a?, b?): CFEqual(a, b)
    default: false
    }
  }

  /// When the field exposes its text, the cursor must still sit right after
  /// the insertion (the user did not type or move the cursor meanwhile).
  private static func fieldStillEndsWith(_ text: String, element: AXUIElement?) -> Bool {
    guard element != nil, let before = LiveTyper.textBeforeCursor(count: text.count) else { return true }
    return before == text || before.hasSuffix(text)
  }

  private static func leadingSpaceIfNeeded(_ text: String, after previous: String) -> String {
    guard let last = previous.last, !last.isWhitespace, let first = text.first, !first.isWhitespace,
          !".,;:!?)".contains(first) else { return text }
    return " " + text
  }
}
