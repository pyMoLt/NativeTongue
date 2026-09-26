import Foundation

/// Immutable lookup structure over lexicon entries (plan 5.7).
///
/// - exact terms and aliases (case-insensitive, whitespace-normalized)
/// - a trigram index over `PhoneticKey.base` for fuzzy candidates
///
/// Trigrams of the base key (alphabet a–z plus boundary markers) are packed
/// into 15-bit codes, so postings live in a flat array instead of a string
/// dictionary. Build once in the background; queries are thread-safe.
public final class LexiconIndex: Sendable {
	public struct Item: Sendable {
		public let entry: LexiconEntry
		/// User lexicon entry (highest priority).
		public let isUser: Bool
		/// Profile of the pack the entry comes from (`nil` for user entries or neutral packs).
		public let packProfile: ASRProfile?
		public let baseKey: String
		public let languageKey: String
	}

	public let items: [Item]
	private let exact: [String: [Int32]]
	private let aliases: [String: [Int32]]
	private let postings: [[Int32]]
	private let keyTrigramCounts: [UInt16]

	public var count: Int { items.count }

	public convenience init(userEntries: [LexiconEntry] = [], packs: [LexiconPack] = []) {
		var sources: [(entries: [LexiconEntry], isUser: Bool, profile: ASRProfile?)] = []
		if !userEntries.isEmpty { sources.append((userEntries, true, nil)) }
		for pack in packs { sources.append((pack.entries, false, pack.profile)) }
		self.init(sources: sources)
	}

	public init(sources: [(entries: [LexiconEntry], isUser: Bool, profile: ASRProfile?)]) {
		var items: [Item] = []
		items.reserveCapacity(sources.reduce(0) { $0 + $1.entries.count })
		var exact: [String: [Int32]] = [:]
		var aliases: [String: [Int32]] = [:]
		var postings = [[Int32]](repeating: [], count: 1 << 15)
		var trigramCounts: [UInt16] = []
		for source in sources {
			for entry in source.entries where !entry.term.isEmpty {
				let index = Int32(items.count)
				let base = PhoneticKey.base(entry.term)
				items.append(Item(
					entry: entry,
					isUser: source.isUser,
					packProfile: source.isUser ? entry.profile : source.profile,
					baseKey: base,
					languageKey: PhoneticKey.key(entry.term, language: entry.lang)
				))
				exact[Self.normalize(entry.term), default: []].append(index)
				for alias in entry.aliases where !alias.isEmpty {
					aliases[Self.normalize(alias), default: []].append(index)
				}
				let codes = Self.trigrams(base)
				trigramCounts.append(UInt16(min(codes.count, Int(UInt16.max))))
				for code in Set(codes) { postings[code].append(index) }
			}
		}
		self.items = items
		self.exact = exact
		self.aliases = aliases
		self.postings = postings
		self.keyTrigramCounts = trigramCounts
	}

	/// Lowercased, single-spaced lookup form.
	public static func normalize(_ text: String) -> String {
		text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	public func exactMatches(_ text: String) -> [Item] {
		exact[Self.normalize(text)]?.map { items[Int($0)] } ?? []
	}

	public func aliasMatches(_ text: String) -> [Item] {
		aliases[Self.normalize(text)]?.map { items[Int($0)] } ?? []
	}

	/// Entries sharing ≥ `minimumShare` of the query's base-key trigrams,
	/// best overlap first (Dice coefficient), at most `limit`.
	public func candidates(for text: String, minimumShare: Double = 0.3, limit: Int = 300) -> [Item] {
		let query = Self.trigrams(PhoneticKey.base(text))
		let unique = Array(Set(query))
		guard !unique.isEmpty, !items.isEmpty else { return [] }
		var shared = [UInt8](repeating: 0, count: items.count)
		var touched: [Int32] = []
		for code in unique {
			for index in postings[code] {
				let i = Int(index)
				if shared[i] == 0 { touched.append(index) }
				if shared[i] < UInt8.max { shared[i] += 1 }
			}
		}
		let needed = max(1, Int((Double(unique.count) * minimumShare).rounded(.up)))
		var scored: [(index: Int32, dice: Double)] = []
		for index in touched {
			let common = Int(shared[Int(index)])
			guard common >= needed else { continue }
			let dice = 2 * Double(common) / Double(unique.count + Int(keyTrigramCounts[Int(index)]))
			scored.append((index, dice))
		}
		scored.sort { $0.dice > $1.dice }
		return scored.prefix(limit).map { items[Int($0.index)] }
	}

	/// Packed trigram codes of `^key$` (5 bits per symbol).
	static func trigrams(_ key: String) -> [Int] {
		guard !key.isEmpty else { return [] }
		var symbols: [Int] = [27]
		for scalar in key.unicodeScalars {
			let value = Int(scalar.value)
			if value >= 97, value <= 122 { symbols.append(value - 96) }
		}
		symbols.append(28)
		guard symbols.count >= 3 else { return [] }
		return (0 ..< symbols.count - 2).map { symbols[$0] << 10 | symbols[$0 + 1] << 5 | symbols[$0 + 2] }
	}
}
