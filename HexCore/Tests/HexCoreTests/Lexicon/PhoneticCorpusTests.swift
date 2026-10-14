import XCTest
@testable import HexCore

/// Plan B7: misrecognised domain terms → term, without false positives on ordinary text.
final class PhoneticCorpusTests: XCTestCase {
	private static let terms = [
		"Rivaroxaban", "Apixaban", "Metoprolol", "Pantoprazol", "Ibuprofen", "Amoxicillin", "Levothyroxin", "Bisoprolol",
		"Ramipril", "Simvastatin", "Candesartan", "Torasemid", "Enoxaparin", "Mycophenolatmofetil", "Glomerulonephritis",
		"Cholezystektomie", "Appendizitis", "Pneumothorax", "Ileum", "Ilium", "Nävus", "Nervus",
	]
	private let pack = LexiconPack(id: "medical-de", entries: terms.map { term in
		var entry = LexiconEntry(term: term, lang: term == "Ileum" || term == "Ilium" || term == "Nervus" ? "la" : "de", category: "drug")
		switch term {
		case "Ileum": entry.confusableWith = ["Ilium"]
		case "Ilium": entry.confusableWith = ["Ileum"]
		case "Nävus": entry.confusableWith = ["Nervus", "Naevus"]
		case "Nervus": entry.confusableWith = ["Nävus"]
		default: break
		}
		return entry
	})

	private func corrector(_ mode: DictationMode = .literal) -> LexiconCorrector {
		LexiconCorrector(indexes: [LexiconIndex(packs: [pack])], wordChecker: SystemWordChecker.shared,
		                 options: .init(mode: mode, language: "de", profile: .medical))
	}

	private func run(_ text: String, _ mode: DictationMode = .literal) -> (String, [LexiconCorrection], [LexiconHint]) {
		let result = corrector(mode).correctWithHints(ModelTextTokenizer.tokenize(text))
		return (result.tokens.compactMap(\.wordText).joined(separator: " "), result.corrections, result.hints)
	}

	func testMisrecognitionsBecomeTheTerm() {
		let cases: [(String, String)] = [
			("Ribaroxaban", "Rivaroxaban"), ("Rivaroksaban", "Rivaroxaban"), ("Apiksaban", "Apixaban"), ("Metoprolohl", "Metoprolol"),
			("Pantopratsol", "Pantoprazol"), ("Ibuprofehn", "Ibuprofen"), ("Amoxizillin", "Amoxicillin"), ("Levotyroxin", "Levothyroxin"),
			("Bisoprolohl", "Bisoprolol"), ("Simwastatin", "Simvastatin"), ("Candesartahn", "Candesartan"), ("Enoxaparien", "Enoxaparin"),
			("Mykophenolatmofetil", "Mycophenolatmofetil"), ("Glomerulonefritis", "Glomerulonephritis"), ("Cholezystektomi", "Cholezystektomie"),
			("Apendizitis", "Appendizitis"), ("Pneumotorax", "Pneumothorax"),
		]
		var replaced = 0
		var report: [String] = []
		for (input, term) in cases {
			let (output, _, hints) = run("Gabe von \(input) heute")
			if output == "Gabe von \(term) heute" { replaced += 1 } else { report.append("\(input)→\(output) hints=\(hints.map(\.suggestion))") }
		}
		print("PHONETIC_CORPUS replaced=\(replaced)/\(cases.count) misses=\(report)")
		XCTAssertGreaterThanOrEqual(replaced, cases.count - 2, report.joined(separator: "; "))
	}

	func testConfusablePairsAreNeverSwapped() {
		for word in ["Ileum", "Ilium", "Nervus", "Nävus"] {
			XCTAssertEqual(run("Befund am \(word) unauffällig").0, "Befund am \(word) unauffällig", word)
		}
	}

	func testOrdinaryTextStaysUntouched() {
		let text = """
		Der Patient kam heute Morgen in die Praxis und berichtete über Kopfschmerzen seit drei Tagen. \
		Er schläft schlecht, trinkt zu wenig und arbeitet viel am Computer. Wir besprechen eine Entlastung, \
		regelmäßige Pausen und ausreichend Bewegung. Die Kontrolle erfolgt in zwei Wochen, bei Verschlechterung früher. \
		Außerdem empfehlen wir Spaziergänge, Gespräche mit Freunden und eine feste Schlafenszeit. Morgen ruft die Tochter an.
		"""
		for mode in [DictationMode.literal, .normal] {
			let (output, corrections, hints) = run(text, mode)
			XCTAssertEqual(corrections, [], "\(mode)")
			XCTAssertEqual(hints, [], "\(mode)")
			XCTAssertEqual(output, ModelTextTokenizer.tokenize(text).compactMap(\.wordText).joined(separator: " "))
		}
	}

	func testMediumConfidenceBecomesAHintInTheDocument() {
		let weak = LexiconCorrector(indexes: [LexiconIndex(packs: [pack])], wordChecker: SystemWordChecker.shared,
		                            options: .init(mode: .normal, language: "de", profile: .medical))
		let aligned = [AlignedUtterance(utterance: Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: 900, pauseAfterMs: 900), text: "Gabe von Ribaroksabahn heute")]
		let document = DictationSessionProcessor.makeDocument(from: aligned, options: .init(mode: .normal, formatNumbers: false), corrector: weak)
		XCTAssertEqual(document.render(.init(language: "de", mode: .normal)), "Gabe von Ribaroksabahn heute", "Normal never fuzzy-replaces pack terms")
		XCTAssertEqual(document.hints.map(\.suggestion), ["Rivaroxaban"])
	}
}
