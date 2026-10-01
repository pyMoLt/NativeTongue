import Foundation

/// One transcribed utterance of an audio file (plan 5.11).
public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
	public var id: Int
	public var start: Double
	public var end: Double
	public var text: String
	/// 0-based speaker index from diarization; `nil` = unknown / not diarized.
	public var speaker: Int?

	public init(id: Int, start: Double, end: Double, text: String, speaker: Int? = nil) {
		self.id = id
		self.start = start
		self.end = end
		self.text = text
		self.speaker = speaker
	}
}

/// A contiguous stretch of speech attributed to one speaker.
public struct SpeakerTurn: Sendable, Equatable {
	public var start: Double
	public var end: Double
	public var speaker: Int

	public init(start: Double, end: Double, speaker: Int) {
		self.start = start
		self.end = end
		self.speaker = speaker
	}
}

public enum SpeakerAssigner {
	/// Gives every segment the speaker with the largest time overlap. Segments
	/// without any overlap take the nearest turn's speaker.
	public static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
		guard !turns.isEmpty else { return segments }
		return segments.map { segment in
			var overlap: [Int: Double] = [:]
			for turn in turns {
				let shared = min(segment.end, turn.end) - max(segment.start, turn.start)
				if shared > 0 { overlap[turn.speaker, default: 0] += shared }
			}
			var result = segment
			if let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
				result.speaker = best.key
			} else {
				let middle = (segment.start + segment.end) / 2
				result.speaker = turns.min { abs(($0.start + $0.end) / 2 - middle) < abs(($1.start + $1.end) / 2 - middle) }?.speaker
			}
			return result
		}
	}

	/// Renumbers speakers by first appearance (0, 1, 2 …) so labels read naturally.
	public static func normalizeOrder(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
		var mapping: [Int: Int] = [:]
		return segments.map { segment in
			var result = segment
			if let speaker = segment.speaker {
				if mapping[speaker] == nil { mapping[speaker] = mapping.count }
				result.speaker = mapping[speaker]
			}
			return result
		}
	}
}

/// TXT / Markdown / SRT / VTT export (plan 5.11).
public enum TranscriptExporter {
	public enum Format: String, CaseIterable, Sendable {
		case text, markdown, srt, vtt

		public var fileExtension: String {
			switch self {
			case .text: "txt"
			case .markdown: "md"
			case .srt: "srt"
			case .vtt: "vtt"
			}
		}
	}

	public static func export(_ segments: [TranscriptSegment], format: Format, speakerNames: [Int: String] = [:], title: String? = nil) -> String {
		switch format {
		case .text: plainText(segments, speakerNames: speakerNames)
		case .markdown: markdown(segments, speakerNames: speakerNames, title: title)
		case .srt: subtitles(segments, speakerNames: speakerNames, vtt: false)
		case .vtt: subtitles(segments, speakerNames: speakerNames, vtt: true)
		}
	}

	public static func speakerName(_ index: Int?, names: [Int: String]) -> String? {
		guard let index else { return nil }
		return names[index] ?? "Speaker \(index + 1)"
	}

	/// Consecutive segments of the same speaker form one paragraph.
	static func paragraphs(_ segments: [TranscriptSegment]) -> [[TranscriptSegment]] {
		var result: [[TranscriptSegment]] = []
		for segment in segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			if let last = result.last?.last, last.speaker == segment.speaker, segment.speaker != nil {
				result[result.count - 1].append(segment)
			} else if segment.speaker == nil, let last = result.last?.last, last.speaker == nil {
				result[result.count - 1].append(segment)
			} else {
				result.append([segment])
			}
		}
		return result
	}

	public static func plainText(_ segments: [TranscriptSegment], speakerNames: [Int: String] = [:]) -> String {
		paragraphs(segments).map { group in
			let text = join(group)
			if let name = speakerName(group[0].speaker, names: speakerNames) { return "\(name): \(text)" }
			return text
		}
		.joined(separator: "\n\n")
	}

	public static func markdown(_ segments: [TranscriptSegment], speakerNames: [Int: String] = [:], title: String? = nil) -> String {
		var out: [String] = []
		if let title { out.append("# \(title)") }
		for group in paragraphs(segments) {
			if let name = speakerName(group[0].speaker, names: speakerNames) {
				out.append("### \(name) · \(clock(group[0].start))")
			}
			out.append(join(group))
		}
		return out.joined(separator: "\n\n")
	}

	private static func join(_ group: [TranscriptSegment]) -> String {
		group.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	// MARK: Subtitles

	public static let maxLineLength = 42
	public static let maxLines = 2

	public static func subtitles(_ segments: [TranscriptSegment], speakerNames: [Int: String] = [:], vtt: Bool) -> String {
		var cues: [(start: Double, end: Double, lines: [String])] = []
		for segment in segments {
			let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { continue }
			let prefix = speakerName(segment.speaker, names: speakerNames).map { vtt ? "<v \($0)>" : "\($0): " } ?? ""
			let lines = wrap(text, width: maxLineLength)
			let chunks = stride(from: 0, to: lines.count, by: maxLines).map { Array(lines[$0 ..< min($0 + maxLines, lines.count)]) }
			let totalCharacters = max(chunks.reduce(0) { $0 + $1.joined(separator: " ").count }, 1)
			var cursor = segment.start
			let duration = max(segment.end - segment.start, 0.5)
			for (index, chunk) in chunks.enumerated() {
				let share = Double(chunk.joined(separator: " ").count) / Double(totalCharacters)
				let end = index == chunks.count - 1 ? segment.start + duration : cursor + duration * share
				var chunkLines = chunk
				if index == 0, !prefix.isEmpty { chunkLines[0] = prefix + chunkLines[0] }
				cues.append((cursor, end, chunkLines))
				cursor = end
			}
		}
		var out: [String] = vtt ? ["WEBVTT", ""] : []
		for (index, cue) in cues.enumerated() {
			if !vtt { out.append("\(index + 1)") }
			out.append("\(timestamp(cue.start, vtt: vtt)) --> \(timestamp(cue.end, vtt: vtt))")
			out.append(contentsOf: cue.lines)
			out.append("")
		}
		return out.joined(separator: "\n")
	}

	/// Greedy word wrap; words longer than `width` stay on their own line.
	public static func wrap(_ text: String, width: Int) -> [String] {
		var lines: [String] = []
		var current = ""
		for word in text.split(whereSeparator: \.isWhitespace) {
			if current.isEmpty {
				current = String(word)
			} else if current.count + 1 + word.count <= width {
				current += " " + word
			} else {
				lines.append(current)
				current = String(word)
			}
		}
		if !current.isEmpty { lines.append(current) }
		return lines
	}

	/// 00:01:02,500 (SRT) or 00:01:02.500 (VTT).
	public static func timestamp(_ seconds: Double, vtt: Bool) -> String {
		let totalMilliseconds = Int((max(seconds, 0) * 1_000).rounded())
		let hours = totalMilliseconds / 3_600_000
		let minutes = totalMilliseconds / 60_000 % 60
		let secs = totalMilliseconds / 1_000 % 60
		let millis = totalMilliseconds % 1_000
		return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, vtt ? "." : ",", millis)
	}

	/// m:ss or h:mm:ss for display.
	public static func clock(_ seconds: Double) -> String {
		let total = Int(max(seconds, 0))
		if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60) }
		return String(format: "%d:%02d", total / 60, total % 60)
	}
}

/// Groups VAD utterances into decoding blocks of about `targetSeconds`, cut at
/// utterance boundaries, so long files keep acoustic context (whole-block
/// decoding) while progress stays measurable.
public enum FileBlockPlanner {
	public static func blocks(_ utterances: [Utterance], sampleRate: Int = 16_000, targetSeconds: Double = 240) -> [[Utterance]] {
		var result: [[Utterance]] = []
		var current: [Utterance] = []
		for utterance in utterances {
			current.append(utterance)
			let length = Double(current.last!.range.upperBound - current.first!.range.lowerBound) / Double(sampleRate)
			if length >= targetSeconds {
				result.append(current)
				current = []
			}
		}
		if !current.isEmpty { result.append(current) }
		return result
	}
}
