import XCTest
@testable import HexCore

final class FileTranscriptTests: XCTestCase {
	private let segments = [
		TranscriptSegment(id: 0, start: 0.0, end: 2.5, text: "Hallo zusammen.", speaker: 0),
		TranscriptSegment(id: 1, start: 2.8, end: 5.0, text: "Heute geht es um das Projekt.", speaker: 0),
		TranscriptSegment(id: 2, start: 5.4, end: 9.9, text: "Danke, ich habe eine Frage zu den Zahlen aus dem letzten Quartal und zum Zeitplan.", speaker: 1),
	]

	func testSpeakerAssignmentByOverlap() {
		let plain = segments.map { var s = $0; s.speaker = nil; return s }
		let turns = [SpeakerTurn(start: 0, end: 5.2, speaker: 7), SpeakerTurn(start: 5.2, end: 10, speaker: 3)]
		let assigned = SpeakerAssigner.normalizeOrder(SpeakerAssigner.assign(plain, turns: turns))
		XCTAssertEqual(assigned.map(\.speaker), [0, 0, 1])
		let gap = [TranscriptSegment(id: 0, start: 20, end: 21, text: "x")]
		XCTAssertEqual(SpeakerAssigner.assign(gap, turns: turns).first?.speaker, 3)
	}

	func testPlainTextAndMarkdownGroupBySpeaker() {
		XCTAssertEqual(
			TranscriptExporter.plainText(segments, speakerNames: [1: "Anna"]),
			"Speaker 1: Hallo zusammen. Heute geht es um das Projekt.\n\nAnna: Danke, ich habe eine Frage zu den Zahlen aus dem letzten Quartal und zum Zeitplan."
		)
		let markdown = TranscriptExporter.markdown(segments, title: "Meeting")
		XCTAssertTrue(markdown.hasPrefix("# Meeting\n\n### Speaker 1 · 0:00\n\nHallo zusammen."))
		XCTAssertTrue(markdown.contains("### Speaker 2 · 0:05"))
	}

	func testSRTAndVTTAreValid() {
		let srt = TranscriptExporter.subtitles(segments, vtt: false)
		let blocks = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
		XCTAssertEqual(blocks.first?.components(separatedBy: "\n").first, "1")
		XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:02,500"))
		for block in blocks {
			let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
			XCTAssertLessThanOrEqual(lines.count - 2, 2, block)
			for line in lines.dropFirst(2) {
				XCTAssertLessThanOrEqual(line.count, 42 + "Speaker 2: ".count, line)
			}
		}
		// The last cue ends at the segment end.
		XCTAssertTrue(srt.contains("--> 00:00:09,900"))
		let vtt = TranscriptExporter.subtitles(segments, vtt: true)
		XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:02.500\n<v Speaker 1>Hallo zusammen."))
	}

	func testLongSegmentIsSplitIntoSeveralCues() {
		let long = [TranscriptSegment(id: 0, start: 0, end: 12, text: String(repeating: "Wort ", count: 40))]
		let srt = TranscriptExporter.subtitles(long, vtt: false)
		let cues = srt.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .newlines).isEmpty }
		XCTAssertGreaterThan(cues.count, 1)
		XCTAssertTrue(srt.contains("--> 00:00:12,000"))
	}

	func testTimestampsAndWrap() {
		XCTAssertEqual(TranscriptExporter.timestamp(3_723.456, vtt: false), "01:02:03,456")
		XCTAssertEqual(TranscriptExporter.clock(65), "1:05")
		XCTAssertEqual(TranscriptExporter.wrap("eins zwei drei", width: 9), ["eins zwei", "drei"])
	}

	func testBlockPlannerCutsAtUtterances() {
		let utterances = (0..<10).map { index in
			Utterance(id: index, range: (index * 60 * 16_000)..<((index * 60 + 50) * 16_000), pauseBeforeMs: 10_000, pauseAfterMs: 10_000)
		}
		let blocks = FileBlockPlanner.blocks(utterances, targetSeconds: 240)
		XCTAssertEqual(blocks.map(\.count), [5, 5])
		XCTAssertEqual(blocks.flatMap { $0 }.map(\.id), Array(0..<10))
	}
}
