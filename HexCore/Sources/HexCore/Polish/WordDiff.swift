import Foundation

/// Word-level difference between two texts for the dictation box diff view.
public enum WordDiff {
	public enum Kind: Equatable, Sendable { case same, removed, added }

	public struct Segment: Equatable, Sendable {
		public let kind: Kind
		public let text: String

		public init(_ kind: Kind, _ text: String) {
			self.kind = kind
			self.text = text
		}
	}

	/// Longest-common-subsequence diff over whitespace-separated words.
	/// Adjacent words of the same kind are merged into one segment.
	public static func diff(_ old: String, _ new: String) -> [Segment] {
		let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
		let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
		// Guard against pathological inputs (box texts are a few hundred words).
		guard a.count * b.count <= 4_000_000 else {
			return [Segment(.removed, old), Segment(.added, new)]
		}
		var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
		for i in stride(from: a.count - 1, through: 0, by: -1) {
			for j in stride(from: b.count - 1, through: 0, by: -1) {
				lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
			}
		}
		var segments: [Segment] = []
		func append(_ kind: Kind, _ word: String) {
			if let last = segments.last, last.kind == kind {
				segments[segments.count - 1] = Segment(kind, last.text + " " + word)
			} else {
				segments.append(Segment(kind, word))
			}
		}
		var i = 0
		var j = 0
		while i < a.count, j < b.count {
			if a[i] == b[j] {
				append(.same, a[i]); i += 1; j += 1
			} else if lcs[i + 1][j] >= lcs[i][j + 1] {
				append(.removed, a[i]); i += 1
			} else {
				append(.added, b[j]); j += 1
			}
		}
		while i < a.count { append(.removed, a[i]); i += 1 }
		while j < b.count { append(.added, b[j]); j += 1 }
		return segments
	}
}
