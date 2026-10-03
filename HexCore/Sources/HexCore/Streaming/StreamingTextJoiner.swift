import Foundation

/// Fits a newly recognised piece of text to what already stands before the
/// cursor (plan 2.5, section 2.1): the user may have typed in between.
public enum StreamingTextJoiner {
	/// - Parameters:
	///   - piece: committed text from the engine (may start with a space).
	///   - before: the character(s) directly before the cursor, if known.
	///   - adapt: false inserts the piece unchanged.
	public static func join(_ piece: String, after before: String?, adapt: Bool) -> String {
		guard adapt else { return piece }
		var text = piece
		let trimmedLeading = text.drop { $0 == " " }
		guard let first = trimmedLeading.first else { return piece }
		let startsWithPunctuation = ".,;:!?)]}”“%".contains(first)
		text = String(trimmedLeading)

		guard let before, let last = before.last else {
			// Start of an empty field: capital letter, no leading space.
			return capitalizedFirst(text)
		}
		let needsSpace = !last.isWhitespace && !"([{„“\"'/-".contains(last) && !startsWithPunctuation
		let sentenceEnded = sentenceEnds(before)
		if sentenceEnded { text = capitalizedFirst(text) }
		return (needsSpace ? " " : "") + text
	}

	/// Whether the text before the cursor ends a sentence (or is empty / a new line).
	static func sentenceEnds(_ before: String) -> Bool {
		let trimmed = before.reversed().drop { $0 == " " || $0 == "\t" }
		guard let last = trimmed.first else { return true }
		return ".!?\n".contains(last)
	}

	static func capitalizedFirst(_ text: String) -> String {
		guard let first = text.first, first.isLowercase else { return text }
		return first.uppercased() + text.dropFirst()
	}
}

/// Energy-based pause detection for emulated streaming: cuts a block after a
/// pause following speech, or when a block grows too long.
public struct StreamingPauseDetector: Sendable {
	public let sampleRate: Int
	public let pauseMs: Int
	public let maxBlockSeconds: Int
	/// RMS above which a 20 ms frame counts as speech.
	public let speechThreshold: Float

	private var block: [Float] = []
	private var heardSpeech = false
	private var silentSamples = 0
	/// Silence since the last speech frame, across blocks (auto-stop).
	private var quietSamples = 0

	public init(sampleRate: Int = 16_000, pauseMs: Int = 600, maxBlockSeconds: Int = 12, speechThreshold: Float = 0.012) {
		self.sampleRate = sampleRate
		self.pauseMs = pauseMs
		self.maxBlockSeconds = maxBlockSeconds
		self.speechThreshold = speechThreshold
	}

	/// Feeds audio; returns finished blocks (speech followed by a pause).
	public mutating func append(_ samples: [Float]) -> [[Float]] {
		var blocks: [[Float]] = []
		let frame = max(sampleRate / 50, 1)
		var index = 0
		while index < samples.count {
			let end = min(index + frame, samples.count)
			let slice = samples[index..<end]
			block.append(contentsOf: slice)
			let rms = (slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
			if rms >= speechThreshold {
				heardSpeech = true
				silentSamples = 0
				quietSamples = 0
			} else {
				silentSamples += slice.count
				quietSamples += slice.count
			}
			let pauseReached = heardSpeech && silentSamples * 1_000 >= pauseMs * sampleRate
			let tooLong = block.count >= maxBlockSeconds * sampleRate
			if pauseReached || (tooLong && heardSpeech) {
				blocks.append(block)
				block = []
				heardSpeech = false
				silentSamples = 0
			} else if !heardSpeech, block.count > sampleRate {
				// Keep only a short lead-in of silence.
				block.removeFirst(block.count - sampleRate / 4)
			}
			index = end
		}
		return blocks
	}

	/// Remaining speech when the session ends (nil if only silence).
	public mutating func flush() -> [Float]? {
		defer { block = []; heardSpeech = false; silentSamples = 0 }
		return heardSpeech ? block : nil
	}

	/// Seconds of silence since the last speech (for auto-stop).
	public var silenceSeconds: Double { Double(quietSamples) / Double(sampleRate) }
}
