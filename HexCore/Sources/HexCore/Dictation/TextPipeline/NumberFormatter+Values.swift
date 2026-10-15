import Foundation

/// Plan B5: times, money, ordinals, phone and house numbers. Each parser
/// returns the replacement tokens and how many input tokens it consumed, or nil.
extension SpokenNumberFormatter {
	typealias Parsed = (tokens: [TextToken], consumed: Int)

	private static func word(_ tokens: [TextToken], _ index: Int) -> String? {
		tokens[safe: index]?.wordText?.lowercased()
	}

	/// Integer value of the number starting at `index` (digits or words), if any.
	private static func integer(_ tokens: [TextToken], at index: Int, english: Bool) -> (value: Int, consumed: Int)? {
		guard let number = parseNumber(tokens, at: index, english: english), !number.isDecimal else { return nil }
		return (number.value, number.consumed)
	}

	// MARK: - Time

	/// „vierzehn Uhr dreißig“ → 14:30 Uhr, „acht Uhr“ → 8 Uhr, „halb drei“ → 2:30 Uhr,
	/// „viertel nach acht“ → 8:15 Uhr, „viertel vor neun“ / „dreiviertel neun“ → 8:45 Uhr;
	/// EN „half past eight“ → 8:30, „quarter to nine“ → 8:45, „eight o'clock“ → 8 o'clock,
	/// „eight thirty pm“ → 8:30 pm.
	static func parseTime(_ tokens: [TextToken], at start: Int, english: Bool) -> Parsed? {
		guard let first = word(tokens, start) else { return nil }
		func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%d:%02d", hour, minute) }
		func previousHour(_ hour: Int) -> Int { hour == 1 ? 12 : (hour == 0 ? 23 : hour - 1) }
		if english {
			if ["half", "quarter"].contains(first), let relation = word(tokens, start + 1), ["past", "to"].contains(relation),
			   let hour = integer(tokens, at: start + 2, english: true), (0...24).contains(hour.value) {
				let minutes = first == "half" ? 30 : 15
				let text = relation == "past" ? clock(hour.value, minutes) : clock(previousHour(hour.value), 60 - minutes)
				return ([.word(text)], 2 + hour.consumed)
			}
			guard let hour = integer(tokens, at: start, english: true), (0...24).contains(hour.value) else { return nil }
			var index = start + hour.consumed
			if let next = word(tokens, index), ["o'clock", "o’clock", "oclock"].contains(next) {
				return ([.word(String(hour.value)), .word("o'clock")], hour.consumed + 1)
			}
			var minute: Int?
			if let value = integer(tokens, at: index, english: true), (0...59).contains(value.value), value.value >= 10 || word(tokens, index) == "oh" {
				minute = value.value
				index += value.consumed
			}
			if let suffix = word(tokens, index), ["am", "pm", "a.m.", "p.m."].contains(suffix), (1...12).contains(hour.value) {
				let time = minute.map { clock(hour.value, $0) } ?? String(hour.value)
				return ([.word(time), .word(suffix.replacingOccurrences(of: ".", with: ""))], index + 1 - start)
			}
			return nil
		}
		if first == "halb", let hour = integer(tokens, at: start + 1, english: false), (1...24).contains(hour.value) {
			return ([.word(clock(previousHour(hour.value), 30)), .word("Uhr")], 1 + hour.consumed)
		}
		if first == "dreiviertel", let hour = integer(tokens, at: start + 1, english: false), (1...24).contains(hour.value) {
			return ([.word(clock(previousHour(hour.value), 45)), .word("Uhr")], 1 + hour.consumed)
		}
		if first == "viertel", let relation = word(tokens, start + 1), ["nach", "vor"].contains(relation),
		   let hour = integer(tokens, at: start + 2, english: false), (0...24).contains(hour.value) {
			let text = relation == "nach" ? clock(hour.value, 15) : clock(previousHour(hour.value), 45)
			return ([.word(text), .word("Uhr")], 2 + hour.consumed)
		}
		guard let hour = integer(tokens, at: start, english: false), (0...24).contains(hour.value),
		      word(tokens, start + hour.consumed) == "uhr" else { return nil }
		let afterUhr = start + hour.consumed + 1
		if let minute = integer(tokens, at: afterUhr, english: false), (1...59).contains(minute.value) {
			return ([.word(clock(hour.value, minute.value)), .word("Uhr")], hour.consumed + 1 + minute.consumed)
		}
		return ([.word(String(hour.value)), .word("Uhr")], hour.consumed + 1)
	}

	// MARK: - Money

	private static let germanCurrencies: [String: String] = ["euro": "€", "dollar": "$", "pfund": "£", "franken": "CHF"]
	private static let englishCurrencies: [String: String] = ["euro": "€", "euros": "€", "dollar": "$", "dollars": "$", "pound": "£", "pounds": "£"]

	/// „zwölf Euro fünfzig“ / „zwölf Euro und fünfzig Cent“ → 12,50 €; „drei Euro“ → 3 €;
	/// EN „twelve dollars fifty“ → $12.50, „five euros“ → €5.
	static func parseMoney(_ tokens: [TextToken], at start: Int, english: Bool, thousandsSeparator: Bool = false) -> Parsed? {
		guard let amount = parseNumber(tokens, at: start, english: english) else { return nil }
		var index = start + amount.consumed
		guard let currencyWord = word(tokens, index),
		      let symbol = (english ? englishCurrencies : germanCurrencies)[currencyWord] else { return nil }
		index += 1
		var cents: Int?
		var centIndex = index
		if word(tokens, centIndex) == (english ? "and" : "und") { centIndex += 1 }
		if !amount.isDecimal, let value = integer(tokens, at: centIndex, english: english), (1...99).contains(value.value) {
			var end = centIndex + value.consumed
			let centWords: Set<String> = english ? ["cent", "cents", "pence", "p"] : ["cent", "cents"]
			if let next = word(tokens, end), centWords.contains(next) { end += 1 }
			// „zwölf Euro und fünfzig“ needs the word „Cent“ to be money.
			if centIndex == index || end > centIndex + value.consumed {
				cents = value.value
				index = end
			}
		}
		let separator = english ? "." : ","
		var number = amount.isDecimal ? amount.text : String(amount.value)
		if thousandsSeparator, !english, !amount.isDecimal, amount.value >= 1_000 {
			number = LiteralTuningRules.grouped(amount.value)
		}
		if let cents { number += separator + String(format: "%02d", cents) }
		if english {
			return ([.word(symbol == "CHF" ? "CHF " + number : symbol + number)], index - start)
		}
		return ([.word(number), .word(symbol)], index - start)
	}

	// MARK: - Ordinals

	/// Ordinals ≥ 13 as digits: „der zwanzigste Patient“ → „der 20. Patient“,
	/// EN „the twenty-first case“ → „the 21st case“. Smaller ones stay words.
	static func parseOrdinal(_ tokens: [TextToken], at start: Int, english: Bool) -> Parsed? {
		guard let first = word(tokens, start) else { return nil }
		if english {
			guard let value = englishOrdinalValue(first), value >= 13 else { return nil }
			return ([.word(String(value) + englishSuffix(value))], 1)
		}
		guard let value = germanOrdinalValue(first), value >= 13 else { return nil }
		return ([.word("\(value).")], 1)
	}

	private static func englishSuffix(_ value: Int) -> String {
		if (11...13).contains(value % 100) { return "th" }
		switch value % 10 {
		case 1: return "st"
		case 2: return "nd"
		case 3: return "rd"
		default: return "th"
		}
	}

	/// German ordinal of any size („dreiundzwanzigsten“, „hundertste“).
	static func germanOrdinalValue(_ word: String) -> Int? {
		for suffix in ["ster", "sten", "stem", "stes", "ste", "ter", "ten", "tem", "tes", "te"] where word.hasSuffix(suffix) {
			let stem = String(word.dropLast(suffix.count))
			if let value = germanOrdinal(word) { return value }
			if let value = germanCompound(stem), value >= 20 { return value }
		}
		return nil
	}

	static func englishOrdinalValue(_ word: String) -> Int? {
		if let value = englishOrdinal(word) { return value }
		let parts = word.split(separator: "-").map(String.init)
		let tens: [String: Int] = ["fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90]
		if parts.count == 1, let value = tens[word] { return value }
		return nil
	}

	// MARK: - Phone numbers

	private static let germanDigits: [String: String] = [
		"null": "0", "eins": "1", "zwei": "2", "zwo": "2", "drei": "3", "vier": "4", "fünf": "5", "sechs": "6", "sieben": "7", "acht": "8", "neun": "9",
	]
	private static let englishDigits: [String: String] = [
		"zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
	]

	/// At least five digits spoken one by one („null eins sieben eins …“) form
	/// a phone number: area code and number, „+49“ for „plus vier neun“.
	/// German: area code 3 digits for 030/040/069/089, 4 otherwise;
	/// English 10 digits: 555-123-4567.
	static func parsePhone(_ tokens: [TextToken], at start: Int, english: Bool) -> Parsed? {
		let table = english ? englishDigits : germanDigits
		var index = start
		var plus = false
		if word(tokens, index) == "plus" { plus = true; index += 1 }
		var digits = ""
		while let next = word(tokens, index), let digit = table[next] ?? (next.count == 1 && next.first!.isNumber ? next : nil) {
			digits += digit
			index += 1
		}
		// Counting („eins zwei drei vier fünf“) is no phone number: it must start
		// with 0 or +, or be a ten-digit English number.
		guard digits.count >= 5, plus || digits.hasPrefix("0") || (english && digits.count == 10) else { return nil }
		var text: String
		if plus {
			let country = String(digits.prefix(2))
			text = "+\(country) \(digits.dropFirst(2))"
		} else if english, digits.count == 10 {
			let chars = Array(digits)
			text = "\(String(chars[0..<3]))-\(String(chars[3..<6]))-\(String(chars[6...]))"
		} else if !english, digits.hasPrefix("0"), digits.count >= 7 {
			let short = ["030", "040", "069", "089"].contains(String(digits.prefix(3)))
			let areaLength = short ? 3 : 4
			text = "\(digits.prefix(areaLength)) \(digits.dropFirst(areaLength))"
		} else {
			text = digits
		}
		return (text.split(separator: " ").map { .word(String($0)) }, index - start)
	}

	// MARK: - House numbers

	private static let streetSuffixes = ["straße", "strasse", "str.", "weg", "gasse", "platz", "allee", "ring", "damm", "ufer", "chaussee", "street", "road", "avenue", "lane"]

	/// „Hauptstraße zwölf a“ → „Hauptstraße 12a“ (also „Hausnummer drei b“).
	static func parseHouseNumber(_ tokens: [TextToken], at start: Int, english: Bool) -> Parsed? {
		guard start > 0, let previous = word(tokens, start - 1),
		      streetSuffixes.contains(where: { previous.hasSuffix($0) }) || ["hausnummer", "nummer", "nr."].contains(previous),
		      let number = integer(tokens, at: start, english: english), number.value > 0, number.value < 10_000 else { return nil }
		let letterIndex = start + number.consumed
		if let letter = word(tokens, letterIndex), letter.count == 1, ("a"..."h").contains(letter) {
			return ([.word("\(number.value)\(letter)")], number.consumed + 1)
		}
		return ([.word(String(number.value))], number.consumed)
	}
}
