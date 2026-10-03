import Foundation

/// Turns a spelled dictation into characters (plan 5.8 „Buchstabiermodus“):
/// single letters, the German spelling alphabet (DIN 5009, old and new
/// variants), NATO, „groß“/„klein“ before a letter, digits, „Bindestrich“,
/// „Leerzeichen“, „Punkt“.
public enum SpellingInterpreter {
	/// Spelling-alphabet words (DIN 5009, NATO) and letter names, lowercased.
	static var alphabetWords: Set<String> { Set(alphabet.keys) }

	private static let alphabet: [String: String] = {
		var table: [String: String] = [:]
		let german: [(String, String)] = [
			("anton", "a"), ("berta", "b"), ("bertha", "b"), ("cäsar", "c"), ("caesar", "c"), ("charlotte", "c"),
			("dora", "d"), ("düsseldorf", "d"), ("emil", "e"), ("essen", "e"), ("friedrich", "f"), ("frankfurt", "f"),
			("gustav", "g"), ("goslar", "g"), ("heinrich", "h"), ("hamburg", "h"), ("ida", "i"), ("ingelheim", "i"),
			("julius", "j"), ("jena", "j"), ("kaufmann", "k"), ("köln", "k"), ("ludwig", "l"), ("leipzig", "l"),
			("martha", "m"), ("marta", "m"), ("münchen", "m"), ("nordpol", "n"), ("nürnberg", "n"), ("otto", "o"),
			("offenbach", "o"), ("paula", "p"), ("potsdam", "p"), ("quelle", "q"), ("richard", "r"), ("rostock", "r"),
			("samuel", "s"), ("siegfried", "s"), ("salzwedel", "s"), ("theodor", "t"), ("tübingen", "t"),
			("ulrich", "u"), ("unna", "u"), ("viktor", "v"), ("völklingen", "v"), ("wilhelm", "w"), ("wuppertal", "w"),
			("xanthippe", "x"), ("xanten", "x"), ("ypsilon", "y"), ("zacharias", "z"), ("zürich", "z"), ("zwickau", "z"),
			("ärger", "ä"), ("umlaut a", "ä"), ("ökonom", "ö"), ("umlaut o", "ö"), ("übermut", "ü"), ("umlaut u", "ü"),
			("eszett", "ß"), ("scharfes s", "ß"),
		]
		let nato: [(String, String)] = [
			("alpha", "a"), ("alfa", "a"), ("bravo", "b"), ("charlie", "c"), ("delta", "d"), ("echo", "e"),
			("foxtrot", "f"), ("golf", "g"), ("hotel", "h"), ("india", "i"), ("juliett", "j"), ("juliet", "j"),
			("kilo", "k"), ("lima", "l"), ("mike", "m"), ("november", "n"), ("oscar", "o"), ("papa", "p"),
			("quebec", "q"), ("romeo", "r"), ("sierra", "s"), ("tango", "t"), ("uniform", "u"), ("victor", "v"),
			("whiskey", "w"), ("whisky", "w"), ("x-ray", "x"), ("xray", "x"), ("yankee", "y"), ("zulu", "z"),
		]
		for (word, letter) in german + nato { table[word] = letter }
		return table
	}()

	private static let digits: [String: String] = [
		"null": "0", "eins": "1", "zwei": "2", "zwo": "2", "drei": "3", "vier": "4", "fünf": "5", "sechs": "6",
		"sieben": "7", "acht": "8", "neun": "9", "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
		"five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
	]

	private static let symbols: [String: String] = [
		"bindestrich": "-", "minus": "-", "hyphen": "-", "dash": "-", "leerzeichen": " ", "space": " ",
		"punkt": ".", "dot": ".", "period": ".", "unterstrich": "_", "underscore": "_", "schrägstrich": "/", "slash": "/",
	]

	/// The letter a spelling-alphabet word stands for ("anton" → "a"), if any.
	public static func letter(forAlphabetWord word: String) -> String? {
		alphabet[word.lowercased()].flatMap { $0.count == 1 ? $0 : nil }
	}

	public static func interpret(_ text: String) -> String {
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:!?")))
			.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".„“\"'()")) }
			.filter { !$0.isEmpty }
		var output = ""
		var pendingCase: Bool?  // true = upper, false = lower
		var index = 0
		while index < words.count {
			let word = words[index]
			if ["groß", "gross", "großbuchstabe", "capital", "upper", "uppercase"].contains(word) {
				pendingCase = true; index += 1; continue
			}
			if ["klein", "kleinbuchstabe", "lower", "lowercase", "small"].contains(word) {
				pendingCase = false; index += 1; continue
			}
			var character: String?
			var consumed = 1
			if index + 1 < words.count, let letter = alphabet["\(word) \(words[index + 1])"] {
				character = letter
				consumed = 2
			} else if let letter = alphabet[word] {
				character = letter
			} else if let digit = digits[word] ?? (word.count == 1 && word.first!.isNumber ? word : nil) {
				character = digit
			} else if let symbol = symbols[word] {
				character = symbol
			} else if word.count == 1, word.first!.isLetter {
				character = word
			} else if word.count == 2, word.hasSuffix("."), word.first!.isLetter {
				character = String(word.first!)
			}
			if var character {
				if character.first!.isLetter, character != "ß" {
					// Default: first letter upper case, following letters as spoken case (upper for acronyms).
					switch pendingCase {
					case true?: character = character.uppercased()
					case false?: character = character.lowercased()
					case nil: character = character.uppercased()
					}
				}
				output += character
			}
			pendingCase = nil
			index += consumed
		}
		return output
	}
}
