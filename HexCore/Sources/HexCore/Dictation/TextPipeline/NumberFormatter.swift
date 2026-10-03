import Foundation

/// Converts spoken numbers into digits where that is the written convention:
/// with a measurement unit, with a decimal part, for values ≥ 13 and in dates.
/// "zwei Komma fünf Milligramm" → "2,5 mg", "dritter März zweitausendsechsundzwanzig" → "03.03.2026".
public enum SpokenNumberFormatter {
	public static func format(_ tokens: [TextToken], language: String) -> [TextToken] {
		let english = language.lowercased().hasPrefix("en")
		var output: [TextToken] = []
		var i = 0
		while i < tokens.count {
			if let (dateTokens, consumed) = parseDate(tokens, at: i, english: english) {
				output += dateTokens
				i += consumed
				continue
			}
			if let number = parseNumber(tokens, at: i, english: english) {
				var j = i + number.consumed
				var rendered = number.text
				var unitSymbol: String?
				if let unit = matchUnit(tokens, at: j, english: english) {
					unitSymbol = unit.symbol
					j += unit.consumed
				}
				if unitSymbol != nil || number.isDecimal || number.value >= 13 {
					if let unitSymbol {
						if unitSymbol == "%" && english {
							rendered += "%"
						} else {
							output.append(.word(rendered))
							rendered = unitSymbol
						}
					}
					output.append(.word(rendered))
					i = j
					continue
				}
			}
			output.append(tokens[i])
			i += 1
		}
		return output
	}

	// MARK: - Numbers

	struct ParsedNumber {
		let text: String
		let value: Int
		let isDecimal: Bool
		let consumed: Int
	}

	static func parseNumber(_ tokens: [TextToken], at start: Int, english: Bool) -> ParsedNumber? {
		guard let integer = parseInteger(tokens, at: start, english: english) else { return nil }
		var consumed = integer.consumed
		var text = String(integer.value)
		var isDecimal = integer.isDigits && integer.raw.contains(where: { $0 == "," || $0 == "." })
		if integer.isDigits { text = integer.raw }
		// Decimal part: "Komma"/"point" followed by digit words.
		if let separator = tokens[safe: start + consumed]?.wordText.map(lowered),
		   separator == (english ? "point" : "komma") {
			var digits = ""
			var k = start + consumed + 1
			while let word = tokens[safe: k]?.wordText.map(lowered), let value = cardinal(word, english: english) {
				digits += String(value)
				k += 1
				if value > 9 { break }
			}
			if !digits.isEmpty {
				text += (english ? "." : ",") + digits
				consumed = k - start
				isDecimal = true
			}
		}
		return ParsedNumber(text: text, value: integer.value, isDecimal: isDecimal, consumed: consumed)
	}

	private struct ParsedInteger {
		let value: Int
		let consumed: Int
		let isDigits: Bool
		let raw: String
	}

	private static func parseInteger(_ tokens: [TextToken], at start: Int, english: Bool) -> ParsedInteger? {
		guard let first = tokens[safe: start]?.wordText else { return nil }
		if first.range(of: #"^\d+([.,]\d+)?$"#, options: .regularExpression) != nil {
			let value = Int(first.split(whereSeparator: { $0 == "," || $0 == "." }).first ?? "") ?? 0
			return ParsedInteger(value: value, consumed: 1, isDigits: true, raw: first)
		}
		var total = 0
		var current = 0
		var consumed = 0
		var sawNumber = false
		while let word = tokens[safe: start + consumed]?.wordText.map(lowered) {
			if word == "hundert" || word == "hundred" {
				current = max(current, 1) * 100
			} else if word == "tausend" || word == "thousand" {
				total += max(current, 1) * 1_000
				current = 0
			} else if sawNumber, english, word == "and",
			          let next = tokens[safe: start + consumed + 1]?.wordText.map(lowered), cardinal(next, english: true) != nil {
				consumed += 1
				continue
			} else if let value = cardinal(word, english: english) {
				// Two plain numbers in a row ("zwei drei") are separate numbers.
				if sawNumber && current % 100 != 0 && value < 100 { break }
				if value >= 1_000 { total += value } else { current += value }
			} else {
				break
			}
			sawNumber = true
			consumed += 1
		}
		guard sawNumber else { return nil }
		return ParsedInteger(value: total + current, consumed: consumed, isDigits: false, raw: "")
	}

	private static let germanUnits: [String: Int] = [
		"null": 0, "eins": 1, "ein": 1, "eine": 1, "zwei": 2, "zwo": 2, "drei": 3, "vier": 4, "fünf": 5,
		"sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
	]
	private static let germanTeens: [String: Int] = [
		"zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14, "fünfzehn": 15, "sechzehn": 16,
		"siebzehn": 17, "achtzehn": 18, "neunzehn": 19,
	]
	private static let germanTens: [String: Int] = [
		"zwanzig": 20, "dreißig": 30, "vierzig": 40, "fünfzig": 50, "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90,
	]
	private static let englishSmall: [String: Int] = [
		"zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
		"ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
		"seventeen": 17, "eighteen": 18, "nineteen": 19,
	]
	private static let englishTens: [String: Int] = [
		"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
	]

	/// Value of a single (possibly compound) number word.
	static func cardinal(_ word: String, english: Bool) -> Int? {
		if english {
			if let v = englishSmall[word] ?? englishTens[word] { return v }
			let parts = word.split(separator: "-").map(String.init)
			if parts.count == 2, let tens = englishTens[parts[0]], let unit = englishSmall[parts[1]], unit < 10 { return tens + unit }
			return nil
		}
		return germanCompound(word)
	}

	static func germanCompound(_ word: String) -> Int? {
		guard !word.isEmpty else { return nil }
		if let range = word.range(of: "tausend") {
			let prefix = String(word[..<range.lowerBound])
			let suffix = String(word[range.upperBound...])
			let thousands = prefix.isEmpty ? 1 : germanBelowThousand(prefix)
			let rest = suffix.isEmpty ? 0 : germanBelowThousand(suffix)
			guard let thousands, let rest else { return nil }
			return thousands * 1_000 + rest
		}
		return germanBelowThousand(word)
	}

	private static func germanBelowThousand(_ word: String) -> Int? {
		if let range = word.range(of: "hundert") {
			let prefix = String(word[..<range.lowerBound])
			let suffix = String(word[range.upperBound...])
			let hundreds = prefix.isEmpty ? 1 : germanUnits[prefix]
			let rest = suffix.isEmpty ? 0 : germanBelowHundred(suffix)
			guard let hundreds, hundreds > 0, let rest else { return nil }
			return hundreds * 100 + rest
		}
		return germanBelowHundred(word)
	}

	private static func germanBelowHundred(_ word: String) -> Int? {
		if let v = germanUnits[word] ?? germanTeens[word] ?? germanTens[word] { return v }
		if let range = word.range(of: "und") {
			let unit = germanUnits[String(word[..<range.lowerBound])]
			let tens = germanTens[String(word[range.upperBound...])]
			if let unit, let tens, unit > 0 { return tens + unit }
		}
		return nil
	}

	// MARK: - Units

	private static let germanUnitTable: [([String], String)] = [
		(["milligramm", "pro", "kilogramm"], "mg/kg"), (["millimeter", "quecksilbersäule"], "mmHg"),
		(["internationale", "einheiten"], "IE"), (["grad", "celsius"], "°C"), (["schläge", "pro", "minute"], "/min"),
		(["milligramm"], "mg"), (["mikrogramm"], "µg"), (["gramm"], "g"), (["kilogramm"], "kg"),
		(["milliliter"], "ml"), (["liter"], "l"), (["prozent"], "%"), (["zentimeter"], "cm"),
		(["millimeter"], "mm"), (["meter"], "m"), (["milligramm", "prozent"], "mg%"),
	]
	private static let englishUnitTable: [([String], String)] = [
		(["milligrams", "per", "kilogram"], "mg/kg"), (["milligram", "per", "kilogram"], "mg/kg"),
		(["millimeters", "of", "mercury"], "mmHg"), (["international", "units"], "IU"),
		(["degrees", "celsius"], "°C"), (["beats", "per", "minute"], "bpm"),
		(["milligrams"], "mg"), (["milligram"], "mg"), (["micrograms"], "µg"), (["microgram"], "µg"),
		(["grams"], "g"), (["gram"], "g"), (["kilograms"], "kg"), (["kilogram"], "kg"),
		(["milliliters"], "ml"), (["milliliter"], "ml"), (["liters"], "l"), (["liter"], "l"),
		(["percent"], "%"), (["centimeters"], "cm"), (["centimeter"], "cm"),
		(["millimeters"], "mm"), (["millimeter"], "mm"),
	]

	/// Unit phrases (lowercased words) for joining phrases split by a pause.
	static func unitPhrases(english: Bool) -> [[String]] {
		(english ? englishUnitTable : germanUnitTable).map(\.0)
	}

	/// A word that may continue a number, date or measurement still being
	/// spoken ("zwei", "Komma", "dritter", "März", "Milli…"); used by streaming
	/// to hold such words back until the value is complete.
	static func mayContinueValue(_ word: String, english: Bool) -> Bool {
		let lower = word.lowercased()
		if isNumberWord(lower, english: english) { return true }
		if lower == (english ? "point" : "komma") { return true }
		if (english ? englishOrdinal(lower) : germanOrdinal(lower)) != nil { return true }
		if english ? englishMonths[lower] != nil : germanMonths[lower] != nil { return true }
		return unitPhrases(english: english).contains { $0.first == lower }
	}

	/// A single word that reads as a number ("38,5", "fünf", "zwanzig").
	static func isNumberWord(_ word: String, english: Bool) -> Bool {
		if word.contains(where: \.isNumber) { return true }
		return parseNumber([.word(word)], at: 0, english: english) != nil
	}

	static func matchUnit(_ tokens: [TextToken], at start: Int, english: Bool) -> (symbol: String, consumed: Int)? {
		let table = (english ? englishUnitTable : germanUnitTable).sorted { $0.0.count > $1.0.count }
		for (words, symbol) in table {
			var ok = true
			for (offset, expected) in words.enumerated() {
				guard tokens[safe: start + offset]?.wordText.map(lowered) == expected else { ok = false; break }
			}
			if ok { return (symbol, words.count) }
		}
		return nil
	}

	// MARK: - Dates

	private static let germanMonths: [String: Int] = [
		"januar": 1, "jänner": 1, "februar": 2, "märz": 3, "april": 4, "mai": 5, "juni": 6, "juli": 7,
		"august": 8, "september": 9, "oktober": 10, "november": 11, "dezember": 12,
	]
	private static let englishMonths: [String: (Int, String)] = [
		"january": (1, "January"), "february": (2, "February"), "march": (3, "March"), "april": (4, "April"),
		"may": (5, "May"), "june": (6, "June"), "july": (7, "July"), "august": (8, "August"),
		"september": (9, "September"), "october": (10, "October"), "november": (11, "November"), "december": (12, "December"),
	]

	static func germanOrdinal(_ word: String) -> Int? {
		// Irregular stems: erste(r), dritte(r), siebte(r), achte(r).
		let special: [String: Int] = ["ers": 1, "drit": 3, "sieb": 7, "ach": 8]
		for suffix in ["ster", "sten", "stem", "stes", "ste", "ter", "ten", "tem", "tes", "te"] where word.hasSuffix(suffix) {
			let stem = String(word.dropLast(suffix.count))
			if let v = special[stem] { return v }
			if let v = germanCompound(stem), (1...31).contains(v) { return v }
		}
		return nil
	}

	static func englishOrdinal(_ word: String) -> Int? {
		let table: [String: Int] = [
			"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
			"tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
			"seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
		]
		if let v = table[word] { return v }
		let parts = word.split(separator: "-").map(String.init)
		if parts.count == 2, let tens = englishTens[parts[0]], let unit = table[parts[1]], unit < 10 { return tens + unit }
		return nil
	}

	private static func parseDate(_ tokens: [TextToken], at start: Int, english: Bool) -> ([TextToken], Int)? {
		guard let first = tokens[safe: start]?.wordText.map(lowered) else { return nil }
		if english {
			guard let (month, name) = englishMonths[first],
			      let dayWord = tokens[safe: start + 1]?.wordText.map(lowered), let day = englishOrdinal(dayWord) else { return nil }
			var consumed = 2
			var text = "\(name) \(day)"
			if let year = parseYear(tokens, at: start + 2, english: true) {
				text += ", \(year.value)"
				consumed += year.consumed
			}
			_ = month
			return (text.split(separator: " ").map { .word(String($0)) }, consumed)
		}
		guard let day = germanOrdinal(first),
		      let monthWord = tokens[safe: start + 1]?.wordText.map(lowered), let month = germanMonths[monthWord] else { return nil }
		var consumed = 2
		var text = String(format: "%02d.%02d.", day, month)
		if let year = parseYear(tokens, at: start + 2, english: false) {
			text += String(year.value)
			consumed += year.consumed
		}
		return ([.word(text)], consumed)
	}

	private static func parseYear(_ tokens: [TextToken], at start: Int, english: Bool) -> (value: Int, consumed: Int)? {
		if let number = parseInteger(tokens, at: start, english: english), number.value >= 1_000, number.value <= 2_999 {
			return (number.value, number.consumed)
		}
		// "twenty twenty-six" / "neunzehnhundertneunzig" style.
		if english,
		   let a = tokens[safe: start]?.wordText.map(lowered), let century = cardinal(a, english: true), (10...29).contains(century),
		   let b = tokens[safe: start + 1]?.wordText.map(lowered), let rest = cardinal(b, english: true), (0...99).contains(rest) {
			return (century * 100 + rest, 2)
		}
		if !english, let a = tokens[safe: start]?.wordText.map(lowered), let range = a.range(of: "hundert"),
		   let century = germanCompound(String(a[..<range.lowerBound])), (10...29).contains(century) {
			let restWord = String(a[range.upperBound...])
			let rest = restWord.isEmpty ? 0 : (germanCompound(restWord) ?? -1)
			if rest >= 0 && rest < 100 { return (century * 100 + rest, 1) }
		}
		return nil
	}

	private static func lowered(_ word: String) -> String { word.lowercased() }
}

extension Array {
	subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
