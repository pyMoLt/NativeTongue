import Foundation

/// New text of an append-only running transcript (Nemotron). The usual case,
/// where the earlier text is unchanged, costs O(new text) instead of
/// re-reading the whole transcript on every update (audit L4). A revision of
/// earlier text (the final pass may capitalise) falls back to character counts.
public struct AppendOnlyDelta: Sendable {
	private var emitted = ""
	private var emittedCharacters = 0
	/// Last bytes of `emitted`, checked against the same range of the next update.
	private var tail: [UInt8] = []
	private static let tailLength = 32

	public init() {}

	public mutating func reset() {
		self = AppendOnlyDelta()
	}

	/// The text added since the last call; empty when nothing new arrived.
	public mutating func next(_ running: String) -> (text: String, revisedEarlierText: Bool) {
		let utf8 = running.utf8
		let emittedBytes = emitted.utf8.count
		guard utf8.count > emittedBytes else { return ("", false) }
		let cut = utf8.index(utf8.startIndex, offsetBy: emittedBytes)
		let tailStart = utf8.index(cut, offsetBy: -tail.count)
		if utf8[tailStart..<cut].elementsEqual(tail), let boundary = cut.samePosition(in: running.unicodeScalars),
		   running.unicodeScalars[boundary...].first.map({ !Self.isCombining($0) }) ?? true {
			let new = String(running.unicodeScalars[boundary...])
			remember(running, newCharacters: new.count)
			return (new, false)
		}
		// Earlier text changed: type only characters beyond what was typed.
		let new = String(running.dropFirst(emittedCharacters))
		let revised = running.prefix(emittedCharacters).lowercased() != emitted.lowercased()
		emitted = running
		emittedCharacters = running.count
		tail = Array(running.utf8.suffix(Self.tailLength))
		return (new, revised)
	}

	private mutating func remember(_ running: String, newCharacters: Int) {
		emitted = running
		emittedCharacters += newCharacters
		tail = Array(running.utf8.suffix(Self.tailLength))
	}

	private static func isCombining(_ scalar: Unicode.Scalar) -> Bool {
		scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .spacingMark
			|| scalar.properties.generalCategory == .enclosingMark
	}
}
