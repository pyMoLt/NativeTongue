import Foundation

/// Text stages added in 2.6 (plan stage B). Missing or unknown values fall
/// back to the defaults.
public struct TextProcessingSettings: Codable, Equatable, Sendable {
	/// „am Dienstag, nein, am Mittwoch“ → „am Mittwoch“ (B2).
	public var resolveSelfCorrections = true
	/// Normal mode also turns spoken punctuation („Komma“, „neue Zeile“) into marks (B4).
	public var spokenPunctuationInNormal = false
	/// After how many identical manual corrections in the box NativeTongue
	/// offers „Always replace?“ (B8, 1…5).
	public var learnCorrectionThreshold = 2

	public init(resolveSelfCorrections: Bool = true, spokenPunctuationInNormal: Bool = false, learnCorrectionThreshold: Int = 2) {
		self.resolveSelfCorrections = resolveSelfCorrections
		self.spokenPunctuationInNormal = spokenPunctuationInNormal
		self.learnCorrectionThreshold = min(max(learnCorrectionThreshold, 1), 5)
	}

	private enum CodingKeys: String, CodingKey {
		case resolveSelfCorrections, spokenPunctuationInNormal, learnCorrectionThreshold
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = TextProcessingSettings()
		resolveSelfCorrections = (try? c.decodeIfPresent(Bool.self, forKey: .resolveSelfCorrections)) ?? d.resolveSelfCorrections
		spokenPunctuationInNormal = (try? c.decodeIfPresent(Bool.self, forKey: .spokenPunctuationInNormal)) ?? d.spokenPunctuationInNormal
		let threshold = (try? c.decodeIfPresent(Int.self, forKey: .learnCorrectionThreshold)) ?? d.learnCorrectionThreshold
		learnCorrectionThreshold = min(max(threshold, 1), 5)
	}
}
