import Foundation

/// Whisper part of `LiteralTuning`: decodes speech again that the
/// full-recording pass skipped.
///
/// Whisper's long-form seek can jump over the rest of a 30-s window, e.g. a
/// spoken word list after a pause (test matrix 15.10.2026: 22 % of L9 lost).
/// VAD utterances without enough words are decoded again in three passes
/// (blocks up to 25 s, up to 8 s, then single utterances without padding).
public enum WhisperGapFiller {
	public typealias Decode = @Sendable ([Float]) async throws -> EngineResult

	public static func fill(_ result: EngineResult, samples: [Float], sampleRate: Int = 16_000, decode: Decode) async throws -> EngineResult {
		let rate = Double(sampleRate)
		var config = SegmenterConfig(minPauseMs: 250)
		config.sampleRate = sampleRate
		let utterances = UtteranceSegmenter.segment(samples, config: config)
		guard !utterances.isEmpty else { return result }
		var words = result.words
		let original = Set(words.map(key))
		func seconds(_ u: Utterance) -> (Double, Double) { (Double(u.range.lowerBound) / rate, Double(u.range.upperBound) / rate) }
		func midpoint(_ w: EngineWord) -> Double { (w.start + w.end) / 2 }
		/// At least one word midpoint per 1.5 s of speech: a timestamp stretched
		/// over several utterances does not count as coverage.
		func covered(_ u: Utterance) -> Bool {
			let (s, e) = seconds(u)
			let inside = words.filter { midpoint($0) >= s - 0.1 && midpoint($0) <= e + 0.1 }.count
			return inside >= max(1, Int((e - s) / 1.5))
		}
		/// Single utterances whose own re-decode returned no word at all (noise,
		/// breath): later passes do not try them again. A group of several
		/// utterances that came back empty is retried in smaller pieces — Whisper
		/// skips lists inside a longer window, and the single-utterance pass is
		/// what recovers them.
		var silent = Set<Int>()
		for maxSeconds in [25.0, 8.0, 0.0] {
			try Task.checkCancellation()
			var groups: [Range<Int>] = []
			for u in utterances where !silent.contains(u.id) && !covered(u) {
				if let last = groups.last, maxSeconds > 0, u.range.lowerBound - last.upperBound < sampleRate,
				   Double(u.range.upperBound - last.lowerBound) < maxSeconds * rate {
					groups[groups.count - 1] = last.lowerBound ..< u.range.upperBound
				} else {
					groups.append(u.range)
				}
			}
			guard !groups.isEmpty else { break }
			for group in groups {
				let pad = maxSeconds == 0 ? 0 : sampleRate / 5
				let lower = max(0, group.lowerBound - pad), upper = min(samples.count, group.upperBound + pad)
				guard lower < upper else { continue }
				let part = try await decode(Array(samples[lower ..< upper]))
				let offset = Double(lower) / rate
				let lo = Double(group.lowerBound) / rate - 0.1, hi = Double(group.upperBound) / rate + 0.1
				let inside: (EngineWord) -> Bool = { midpoint($0) >= lo && midpoint($0) <= hi }
				let found = part.words
					.map { EngineWord(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence) }
					.filter(inside)
				if found.isEmpty {
					let members = utterances.filter { group.contains($0.range.lowerBound) }
					if members.count == 1 { silent.insert(members[0].id) }
				}
				// The re-decode replaces the words of the gap when it found more of them.
				if found.count > words.filter(inside).count {
					words.removeAll(where: inside)
					words += found
				}
			}
			words.sort { $0.start < $1.start }
		}
		words = removingDisplacedDuplicates(words, original: original, utterances: utterances, sampleRate: sampleRate)
		guard words != result.words else { return result }
		return EngineResult(text: words.map(\.text).joined(separator: " "), words: words,
		                    detectedLanguage: result.detectedLanguage, punctuationWasSuppressed: result.punctuationWasSuppressed)
	}

	/// A word of the first pass that the re-decode found again is dropped when
	/// it lies outside all speech or within 2 s of the new one: Whisper had
	/// placed it with a wrong timestamp („Punkt“ at 29.7 s instead of 17.7 s).
	static func removingDisplacedDuplicates(_ words: [EngineWord], original: Set<String>, utterances: [Utterance], sampleRate: Int) -> [EngineWord] {
		let rate = Double(sampleRate)
		let added = words.filter { !original.contains(key($0)) }
		guard !added.isEmpty else { return words }
		return words.filter { word in
			guard original.contains(key(word)) else { return true }
			let text = normalized(word.text)
			let twins = added.filter { normalized($0.text) == text }
			guard !twins.isEmpty else { return true }
			if twins.contains(where: { abs($0.start - word.start) <= 2.0 }) { return false }
			let mid = (word.start + word.end) / 2
			let outside = utterances.allSatisfy { u in
				mid < Double(u.range.lowerBound) / rate - 0.5 || mid > Double(u.range.upperBound) / rate + 0.5
			}
			return !outside
		}
	}

	private static func key(_ word: EngineWord) -> String { "\(word.text)|\(word.start)" }
	private static func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
}
