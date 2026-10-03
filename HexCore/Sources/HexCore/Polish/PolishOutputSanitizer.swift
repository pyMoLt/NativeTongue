import Foundation

/// Removes wrapper text small models add around their answer
/// (reasoning blocks, labels, quotes, the input markers).
public enum PolishOutputSanitizer {
	static let stopSequences = ["<<<", "\nText:", "<|im_end|>", "<end_of_turn>", "<|eot_id|>"]

	private static let labels = [
		"corrected text:", "korrigierter text:", "output:", "ausgabe:", "result:", "ergebnis:",
		"rewritten task:", "task:", "aufgabe:", "here is the corrected text:", "hier ist der korrigierte text:",
	]

	public static var generationStopSequences: [String] { stopSequences }

	public static func clean(_ output: String, input: String) -> String {
		var text = output
		// Reasoning blocks, closed or left open at the end.
		while let open = text.range(of: "<think>") {
			if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
				text.removeSubrange(open.lowerBound..<close.upperBound)
			} else {
				text.removeSubrange(open.lowerBound..<text.endIndex)
			}
		}
		text = text.replacingOccurrences(of: ">>>", with: "")
		text = text.trimmingCharacters(in: .whitespacesAndNewlines)

		var changed = true
		while changed {
			changed = false
			let lower = text.lowercased()
			if let label = labels.first(where: { lower.hasPrefix($0) }) {
				text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
				changed = true
			}
		}

		if text.hasPrefix("```"), !input.contains("```") {
			text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
			if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
			text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		for (open, close) in [("\"", "\""), ("„", "“"), ("“", "”"), ("'", "'")]
		where text.count > 1 && text.hasPrefix(open) && text.hasSuffix(close) && !(input.hasPrefix(open) && input.hasSuffix(close)) {
			text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return text
	}
}
