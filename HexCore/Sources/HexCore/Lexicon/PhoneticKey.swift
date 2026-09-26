import Foundation

/// Phonetic keys for fuzzy term lookup (plan 5.7).
public enum PhoneticKey {
	/// Language-neutral base key (port of `build_packs.py → phonetic_key`).
	/// Used for the trigram index.
	public static func base(_ text: String) -> String {
		var s = text.lowercased()
			.replacingOccurrences(of: "ä", with: "e")
			.replacingOccurrences(of: "ö", with: "o")
			.replacingOccurrences(of: "ü", with: "u")
			.replacingOccurrences(of: "ß", with: "s")
		s = String(s.unicodeScalars.filter { $0.value >= 97 && $0.value <= 122 }.map(Character.init))
		for (from, to) in [("ph", "f"), ("th", "t"), ("ck", "k"), ("c", "k"), ("y", "i"), ("v", "f"), ("w", "f"),
		                   ("z", "s"), ("qu", "kw"), ("q", "k"), ("ie", "i"), ("h", "")] {
			s = s.replacingOccurrences(of: from, with: to)
		}
		return collapseRepeats(s)
	}

	/// Key matching the entry language: Kölner Phonetik for German, a
	/// simplified Metaphone for English, the base key for Latin and others.
	public static func key(_ text: String, language: String) -> String {
		switch language {
		case "de": cologne(text)
		case "en": metaphone(text)
		default: base(text)
		}
	}

	// MARK: Kölner Phonetik

	public static func cologne(_ text: String) -> String {
		let letters = Array(text.lowercased()
			.replacingOccurrences(of: "ä", with: "a")
			.replacingOccurrences(of: "ö", with: "o")
			.replacingOccurrences(of: "ü", with: "u")
			.replacingOccurrences(of: "ß", with: "s")
			.filter { $0 >= "a" && $0 <= "z" })
		guard !letters.isEmpty else { return "" }
		var codes: [Character] = []
		for (index, letter) in letters.enumerated() {
			let previous: Character? = index > 0 ? letters[index - 1] : nil
			let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
			let code: String
			switch letter {
			case "a", "e", "i", "j", "o", "u", "y": code = "0"
			case "h": code = "-"
			case "b": code = "1"
			case "p": code = next == "h" ? "3" : "1"
			case "d", "t": code = next.map { "csz".contains($0) } == true ? "8" : "2"
			case "f", "v", "w": code = "3"
			case "g", "k", "q": code = "4"
			case "c":
				if index == 0 {
					code = next.map { "ahkloqrux".contains($0) } == true ? "4" : "8"
				} else if previous.map({ "sz".contains($0) }) == true {
					code = "8"
				} else {
					code = next.map { "ahkoqux".contains($0) } == true ? "4" : "8"
				}
			case "x": code = previous.map { "ckq".contains($0) } == true ? "8" : "48"
			case "l": code = "5"
			case "m", "n": code = "6"
			case "r": code = "7"
			case "s", "z": code = "8"
			default: code = "-"
			}
			codes.append(contentsOf: code)
		}
		var result: [Character] = []
		for code in codes where code != "-" {
			if result.last == code { continue }
			result.append(code)
		}
		// Remove all "0" except at the start.
		let first = result.first
		var tail = result.dropFirst().filter { $0 != "0" }
		if let first { tail.insert(first, at: tail.startIndex) }
		return String(tail)
	}

	// MARK: Simplified Metaphone (English)

	public static func metaphone(_ text: String) -> String {
		var s = text.lowercased().filter { $0 >= "a" && $0 <= "z" }
		guard !s.isEmpty else { return "" }
		for (prefix, replacement) in [("kn", "n"), ("gn", "n"), ("pn", "n"), ("wr", "r"), ("ps", "s"), ("x", "s")] where s.hasPrefix(prefix) {
			s = replacement + s.dropFirst(prefix.count)
			break
		}
		for (from, to) in [("tch", "ch"), ("sch", "sk"), ("ph", "f"), ("gh", "f"), ("ck", "k"), ("sh", "x"), ("ch", "x"),
		                   ("th", "0"), ("dg", "j"), ("wh", "w"), ("qu", "kw"), ("q", "k"), ("x", "ks"), ("z", "s"), ("v", "f")] {
			s = s.replacingOccurrences(of: from, with: to)
		}
		var output: [Character] = []
		let chars = Array(s)
		for (index, char) in chars.enumerated() {
			let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
			switch char {
			case "a", "e", "i", "o", "u":
				if index == 0 { output.append("a") }
			case "c":
				output.append(next.map { "eiy".contains($0) } == true ? "s" : "k")
			case "g":
				output.append(next.map { "eiy".contains($0) } == true ? "j" : "k")
			case "y", "w", "h":
				if let next, "aeiou".contains(next) { output.append(char) }
			case "d": output.append("t")
			case "b": output.append("p")
			default: output.append(char)
			}
		}
		return collapseRepeats(String(output))
	}

	private static func collapseRepeats(_ text: String) -> String {
		var result = ""
		for char in text where result.last != char {
			result.append(char)
		}
		return result
	}
}

/// String similarity measures used by the ranker.
public enum StringSimilarity {
	/// 1 − Levenshtein distance / max length (0…1).
	public static func normalizedLevenshtein(_ a: String, _ b: String) -> Double {
		let lhs = Array(a.unicodeScalars), rhs = Array(b.unicodeScalars)
		let longest = max(lhs.count, rhs.count)
		guard longest > 0 else { return 1 }
		return 1 - Double(levenshtein(lhs, rhs)) / Double(longest)
	}

	static func levenshtein(_ lhs: [Unicode.Scalar], _ rhs: [Unicode.Scalar]) -> Int {
		if lhs.isEmpty { return rhs.count }
		if rhs.isEmpty { return lhs.count }
		var previous = Array(0 ... rhs.count)
		var current = [Int](repeating: 0, count: rhs.count + 1)
		for i in 1 ... lhs.count {
			current[0] = i
			for j in 1 ... rhs.count {
				let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
				current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
			}
			swap(&previous, &current)
		}
		return previous[rhs.count]
	}

	/// Jaro-Winkler similarity (0…1), prefix scale 0.1, max prefix 4.
	public static func jaroWinkler(_ a: String, _ b: String) -> Double {
		let s1 = Array(a.unicodeScalars), s2 = Array(b.unicodeScalars)
		if s1.isEmpty && s2.isEmpty { return 1 }
		if s1.isEmpty || s2.isEmpty { return 0 }
		let window = max(0, max(s1.count, s2.count) / 2 - 1)
		var matched1 = [Bool](repeating: false, count: s1.count)
		var matched2 = [Bool](repeating: false, count: s2.count)
		var matches = 0
		for i in s1.indices {
			let lower = max(0, i - window), upper = min(s2.count - 1, i + window)
			guard lower <= upper else { continue }
			for j in lower ... upper where !matched2[j] && s1[i] == s2[j] {
				matched1[i] = true
				matched2[j] = true
				matches += 1
				break
			}
		}
		guard matches > 0 else { return 0 }
		var transpositions = 0, k = 0
		for i in s1.indices where matched1[i] {
			while !matched2[k] { k += 1 }
			if s1[i] != s2[k] { transpositions += 1 }
			k += 1
		}
		let m = Double(matches)
		let jaro = (m / Double(s1.count) + m / Double(s2.count) + (m - Double(transpositions / 2)) / m) / 3
		var prefix = 0
		while prefix < min(4, s1.count, s2.count), s1[prefix] == s2[prefix] { prefix += 1 }
		return jaro + Double(prefix) * 0.1 * (1 - jaro)
	}
}
