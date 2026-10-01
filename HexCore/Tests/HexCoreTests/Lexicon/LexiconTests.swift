import XCTest
@testable import HexCore

final class PhoneticKeyTests: XCTestCase {
	func testBaseKeyMatchesPrototype() {
		XCTAssertEqual(PhoneticKey.base("Philadelphia"), "filadelfia")
		XCTAssertEqual(PhoneticKey.base("Mycophenolatmofetil"), PhoneticKey.base("Mykofenolatmofetil"))
		XCTAssertEqual(PhoneticKey.base("Glomerulonephritis"), PhoneticKey.base("Glomerulonefritis"))
	}

	func testCologneAndMetaphone() {
		XCTAssertEqual(PhoneticKey.cologne("Müller-Lüdenscheidt"), "65752682")
		XCTAssertEqual(PhoneticKey.cologne("Meier"), PhoneticKey.cologne("Mayr"))
		XCTAssertEqual(PhoneticKey.metaphone("Thompson"), PhoneticKey.metaphone("Tompson").replacingOccurrences(of: "t", with: "0"))
		XCTAssertEqual(PhoneticKey.metaphone("phone"), PhoneticKey.metaphone("fone"))
	}

	func testSimilarity() {
		XCTAssertEqual(StringSimilarity.jaroWinkler("martha", "marhta"), 0.961, accuracy: 0.001)
		XCTAssertEqual(StringSimilarity.normalizedLevenshtein("kitten", "sitting"), 1 - 3.0 / 7.0, accuracy: 0.0001)
		XCTAssertEqual(StringSimilarity.normalizedLevenshtein("", ""), 1)
	}
}

final class LexiconCorrectorTests: XCTestCase {
	private let tech = LexiconPack(id: "technical", entries: [
		LexiconEntry(term: "Qwen", lang: "en", category: "tech", aliases: ["Gwen", "Qn"], confusableWith: ["Queen"]),
		LexiconEntry(term: "PostgreSQL", lang: "en", category: "tech", aliases: ["Postgres SQL"]),
		LexiconEntry(term: "AVFoundation", lang: "en", category: "tech", aliases: ["AV Foundation"]),
		LexiconEntry(term: "FluidAudio", lang: "en", category: "tech", aliases: ["Fluid Audio"]),
		LexiconEntry(term: "GitHub", lang: "en", category: "tech"),
		LexiconEntry(term: "Normal", lang: "en", category: "tech"),
		LexiconEntry(term: "locale", lang: "en", category: "tech", confusableWith: ["local"]),
		LexiconEntry(term: "MIT", lang: "en", category: "tech"),
		LexiconEntry(term: "THE", lang: "en", category: "tech"),
	])
	private let medical = LexiconPack(id: "medical-de", entries: [
		LexiconEntry(term: "Nervus vagus", lang: "de", category: "anatomy"),
		LexiconEntry(term: "Nävus", lang: "de", category: "diagnosis", confusableWith: ["Naevus", "Nervus"]),
		LexiconEntry(term: "Nervus", lang: "la", category: "anatomy", confusableWith: ["Nävus"]),
		LexiconEntry(term: "Mycophenolatmofetil", lang: "de", category: "drug"),
		LexiconEntry(term: "Glomerulonephritis", lang: "de", category: "diagnosis"),
		LexiconEntry(term: "anatomy", lang: "en", category: "general-medical"),
	])
	/// Ordinary German/English words (stand-in for NSSpellChecker).
	private let checker = SetWordChecker(["anatomie", "ähnlich", "lokale", "deutscher", "normal", "nervus", "und", "der", "in"])

	private func corrector(mode: DictationMode = .literal, user: [LexiconEntry] = [], profile: ASRProfile? = .medical) -> LexiconCorrector {
		LexiconCorrector(
			indexes: [LexiconIndex(userEntries: user), LexiconIndex(packs: [tech, medical])],
			wordChecker: checker,
			options: .init(mode: mode, language: "de", profile: profile)
		)
	}

	private func run(_ text: String, _ corrector: LexiconCorrector) -> String {
		let tokens = text.split(separator: " ").map { TextToken.word(String($0)) }
		return corrector.correct(tokens).tokens.compactMap(\.wordText).joined(separator: " ")
	}

	func testAliasesApplyInBothModes() {
		for mode in [DictationMode.literal, .normal] {
			let corrector = corrector(mode: mode)
			XCTAssertEqual(run("wir nutzen Gwen und Postgres SQL", corrector), "wir nutzen Qwen und PostgreSQL")
			XCTAssertEqual(run("AV Foundation und Fluid Audio", corrector), "AVFoundation und FluidAudio")
		}
	}

	func testCasingForBrandsAndMultiWordTerms() {
		let corrector = corrector()
		XCTAssertEqual(run("auf Github und der Nervus Vagus", corrector), "auf GitHub und der Nervus vagus")
		XCTAssertEqual(run("das bleibt normal", corrector), "das bleibt normal")
		XCTAssertEqual(run("mit the Lizenz", corrector), "mit the Lizenz")
	}

	func testFuzzyReplacesOnlyUnknownWordsInLiteral() {
		let corrector = corrector()
		XCTAssertEqual(run("Mycophenolatmophetil und Glomerulonefritis", corrector), "Mycophenolatmofetil und Glomerulonephritis")
		XCTAssertEqual(run("Mykopenolatmophetil", corrector), "Mycophenolatmofetil")
		XCTAssertEqual(run("Anatomie ähnlich lokale deutscher", corrector), "Anatomie ähnlich lokale deutscher")
		// Normal mode never fuzzy-replaces pack terms.
		XCTAssertEqual(run("Mycophenolatmophetil", self.corrector(mode: .normal)), "Mycophenolatmophetil")
	}

	func testConfusablesAreNeverSwapped() {
		let corrector = corrector()
		XCTAssertEqual(run("Nervus", corrector), "Nervus")
		XCTAssertEqual(run("Nävus", corrector), "Nävus")
		XCTAssertEqual(run("Queen", corrector), "Queen")
	}

	func testUserEntriesWinAndRespectProfile() {
		let user = [LexiconEntry(term: "ST-Hebungsinfarkt", lang: "de", category: "user", aliases: ["ST Hebungsinfarkt"], autoReplace: true, profile: .medical)]
		XCTAssertEqual(run("ein ST Hebungsinfarkt", corrector(user: user)), "ein ST-Hebungsinfarkt")
		XCTAssertEqual(run("ein ST Hebungsinfarkt", corrector(user: user, profile: .technical)), "ein ST Hebungsinfarkt")
	}

	func testCorrectionsAreRecordedInDocument() {
		let aligned = [AlignedUtterance(utterance: Utterance(id: 0, range: 0..<16_000, pauseBeforeMs: Int.max, pauseAfterMs: Int.max), text: "wir nutzen Gwen")]
		let document = DictationSessionProcessor.makeDocument(from: aligned, options: .init(mode: .literal, formatNumbers: false), corrector: corrector())
		XCTAssertEqual(document.render(.init(language: "de", mode: .literal)), "Wir nutzen Qwen")
		XCTAssertEqual(document.corrections, [LexiconCorrection(original: "Gwen", replacement: "Qwen", rule: .alias)])
	}

	func testAgentIdentifiersAreNotTouched() {
		XCTAssertEqual(run("`Gwen` qwen_model /gwen", corrector()), "`Gwen` qwen_model /gwen")
	}

	func testSuggestionsRankClosestTermsFirst() {
		let ranker = SuggestionRanker(indexes: [LexiconIndex(packs: [tech, medical])])
		let suggestions = ranker.suggestions(for: "Glomerulonefritis", language: "de", profile: .medical)
		XCTAssertEqual(suggestions.first?.term, "Glomerulonephritis")
		XCTAssertLessThanOrEqual(suggestions.count, 5)
		XCTAssertEqual(ranker.suggestions(for: "Gwen", language: "de", profile: nil).first?.term, "Qwen")
	}
}

final class LexiconStoreTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("lexicon-\(UUID().uuidString)", isDirectory: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	func testUserLexiconRoundTripAndPackImport() throws {
		let store = LexiconStore(directory: directory)
		XCTAssertEqual(try store.loadUser(), UserLexicon())
		let lexicon = UserLexicon(entries: [LexiconEntry(term: "SwiftUI", lang: "en", category: "user", autoReplace: true)])
		try store.saveUser(lexicon)
		XCTAssertEqual(try store.loadUser(), lexicon)

		let source = directory.appendingPathComponent("incoming.json")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data(#"{"id":"technical","version":1,"entries":[{"term":"Qwen","lang":"en","category":"tech","aliases":["Gwen"]}]}"#.utf8).write(to: source)
		let info = try store.importPack(from: source)
		XCTAssertEqual(info.id, "technical")
		XCTAssertEqual(store.installedPacks().map(\.id), ["technical"])
		XCTAssertEqual(try store.loadPack(id: "technical").entries.first?.aliases, ["Gwen"])
		try store.removePack(id: "technical")
		XCTAssertTrue(store.installedPacks().isEmpty)

		try Data(#"{"id":"../evil","entries":[{"term":"x"}]}"#.utf8).write(to: source)
		XCTAssertThrowsError(try store.importPack(from: source))
	}

	func testMigrationFromV1Settings() {
		var settings = HexSettings()
		settings.medicalVocabulary = "ST-Hebungsinfarkt\nApixaban, Rivaroxaban"
		settings.technicalVocabulary = "SwiftUI"
		settings.wordRemappings = [WordRemapping(match: "Gwen", replacement: "Qwen"), WordRemapping(isEnabled: false, match: "a", replacement: "b")]
		let migrated = LexiconMigration.migrate(settings, into: UserLexicon())
		XCTAssertEqual(migrated.entries.map(\.term), ["ST-Hebungsinfarkt", "Apixaban", "Rivaroxaban", "SwiftUI", "Qwen"])
		XCTAssertEqual(migrated.entries.first?.profile, .medical)
		XCTAssertEqual(migrated.entries.last?.aliases, ["Gwen"])
		XCTAssertTrue(migrated.entries.allSatisfy(\.autoReplace))
		// Idempotent.
		XCTAssertEqual(LexiconMigration.migrate(settings, into: migrated), migrated)
	}
}

/// Acceptance with the real packs (plan 5.7). Skipped when the local packs are missing.
final class LexiconPackAcceptanceTests: XCTestCase {
	private static let docs = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent("dev-docs", isDirectory: true)

	private static let index: LexiconIndex? = {
		let packsDirectory = docs.appendingPathComponent("06-wortlisten/packs", isDirectory: true)
		let packs = ["medical-de", "medical-en", "anatomy-la", "technical"].compactMap { id -> LexiconPack? in
			guard let data = try? Data(contentsOf: packsDirectory.appendingPathComponent("\(id).json")) else { return nil }
			return try? JSONDecoder().decode(LexiconPack.self, from: data)
		}
		guard packs.count == 4 else { return nil }
		let start = Date()
		let index = LexiconIndex(packs: packs)
		print("LEXICON_INDEX entries=\(index.count) buildSeconds=\(String(format: "%.2f", Date().timeIntervalSince(start)))")
		return index
	}()

	private func benchmarkText(_ name: String) throws -> String {
		let url = Self.docs.appendingPathComponent("04-tests/ergebnisse/2026-09-26_benchmark-matrix/\(name)--Terminology-de-en.json")
		guard let data = try? Data(contentsOf: url),
		      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let text = json["text"] as? String
		else { throw XCTSkip("benchmark result missing") }
		return text
	}

	func testNoFalseCorrectionsAndAliasesOnRealBenchmarkOutput() throws {
		guard let index = Self.index else { throw XCTSkip("word packs missing") }
		let corrector = LexiconCorrector(
			indexes: [index],
			wordChecker: SystemWordChecker.shared,
			options: .init(mode: .literal, language: "de", profile: .medical)
		)
		let forbidden: Set<String> = ["Anatomie→anatomy", "ähnlich→enolic", "lokale→locale", "deutscher→Deutsche", "normal→Normal",
		                              "mit→MIT", "the→THE", "The→THE"]
		for engine in ["whisper-turbo", "parakeet-ultra", "whisper-large-v3", "canary"] {
			let text = try benchmarkText(engine)
			let tokens = ModelTextTokenizer.tokenize(text)
			let (output, corrections) = corrector.correct(tokens)
			let pairs = Set(corrections.map { "\($0.original)→\($0.replacement)" })
			print("LEXICON_CORRECTIONS engine=\(engine) count=\(corrections.count) \(corrections.map { "\($0.original)→\($0.replacement)[\($0.rule.rawValue)]" })")
			XCTAssertTrue(pairs.isDisjoint(with: forbidden), "\(engine): \(pairs.intersection(forbidden))")
			XCTAssertFalse(corrections.contains { $0.original.lowercased() == "nervus" }, engine)
			let rendered = output.compactMap(\.wordText).joined(separator: " ")
			if text.contains("Postgres SQL") { XCTAssertTrue(rendered.contains("PostgreSQL"), engine) }
			if text.contains("AV Foundation") { XCTAssertTrue(rendered.contains("AVFoundation"), engine) }
			if text.contains("Fluid Audio") { XCTAssertTrue(rendered.contains("FluidAudio"), engine) }
		}
	}

	func testQueryPerformance() throws {
		guard let index = Self.index else { throw XCTSkip("word packs missing") }
		let ranker = SuggestionRanker(indexes: [index])
		let queries = ["Mycophenolatmophetil", "Clomerulonephritis", "Urotelkarzinom", "Tiniacorpores", "Pemprolizumab",
		               "Ribaroxaban", "Maskulus", "Iunum", "Wurzeitstempel", "HuggingFace"]
		let start = Date()
		var top: [String] = []
		for query in queries {
			top.append(ranker.suggestions(for: query, language: "de", profile: .medical).first?.term ?? "-")
		}
		let averageMs = Date().timeIntervalSince(start) * 1_000 / Double(queries.count)
		print("LEXICON_QUERY averageMs=\(String(format: "%.1f", averageMs)) top=\(top)")
		XCTAssertLessThan(averageMs, 30)
		XCTAssertEqual(top[0], "Mycophenolatmofetil")
		XCTAssertEqual(top[1], "Glomerulonephritis")
	}
}
