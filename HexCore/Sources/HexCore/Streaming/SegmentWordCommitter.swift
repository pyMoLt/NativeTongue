import Foundation

/// Types the finished words of an open streaming segment while it is still running.
///
/// Engines like Parakeet (Core AI) report a segment as a growing partial text and
/// finalize it only at a pause. Their decoder never revises tokens it has emitted,
/// so every word followed by a space is final already; only the last word may
/// still grow ("Diktier" → "Diktiergerät,"). Committing up to the last space types
/// text while the speaker is still talking instead of at the next pause.
public struct SegmentWordCommitter: Sendable {
	/// Text of the open segment that was already committed (ends with whitespace).
	private var typed = ""

	public init() {}

	public mutating func reset() {
		typed = ""
	}

	/// New committed text from the segment's running partial, and the volatile tail.
	public mutating func partial(_ running: String) -> (committed: String, pending: String, startsSegment: Bool) {
		let text = Self.trimmedStart(running)
		guard text.hasPrefix(typed) else {
			// The engine revised text we already typed (not expected): wait for the final.
			return ("", Self.dropWords(Self.wordCount(typed), of: text), false)
		}
		let stable = text.lastIndex(where: \.isWhitespace).map { String(text[...$0]) } ?? ""
		var committed = ""
		var starts = false
		if stable.count > typed.count {
			committed = String(stable.dropFirst(typed.count))
			starts = typed.isEmpty
			typed = stable
		}
		return (committed, String(text.dropFirst(typed.count)), starts)
	}

	/// The rest of a finalized segment; the next partial starts a new segment.
	public mutating func final(_ segment: String) -> (committed: String, startsSegment: Bool) {
		defer { typed = "" }
		let text = Self.trimmedStart(segment)
		if typed.isEmpty { return (text, !text.isEmpty) }
		if text.hasPrefix(typed) { return (String(text.dropFirst(typed.count)), false) }
		return (Self.dropWords(Self.wordCount(typed), of: text), false)
	}

	private static func trimmedStart(_ text: String) -> String {
		String(text.drop(while: \.isWhitespace))
	}

	private static func wordCount(_ text: String) -> Int {
		text.split(whereSeparator: \.isWhitespace).count
	}

	private static func dropWords(_ count: Int, of text: String) -> String {
		text.split(whereSeparator: \.isWhitespace).dropFirst(count).joined(separator: " ")
	}
}
