import XCTest
@testable import HexCore

final class ProfileSettingsTests: XCTestCase {
	func testAppPicksItsProfileOtherwiseManual() {
		var settings = HexSettings()
		settings.dictationMode = .normal
		XCTAssertEqual(settings.profiles.profile(forApp: "com.apple.dt.Xcode").id, ProfileSettings.codingID)
		XCTAssertEqual(settings.profiles.profile(forApp: "com.apple.mail").id, ProfileSettings.mailID)
		XCTAssertEqual(settings.profiles.profile(forApp: "ai.perplexity.mac").id, ProfileSettings.aiPromptID)
		XCTAssertEqual(settings.effective(forApp: "com.openai.chat").postProcessing.autoStyleID, AIStyleCatalog.promptID)
		XCTAssertEqual(settings.effective(forApp: "com.openai.chat").postProcessing.context.use, .appOnly)
		XCTAssertEqual(settings.profiles.profile(forApp: "com.example.unknown").id, ProfileSettings.generalID)
		XCTAssertEqual(settings.profiles.profile(forApp: nil).id, ProfileSettings.generalID)
		settings.profiles.switchByApp = false
		settings.profiles.manualProfileID = ProfileSettings.medicalID
		XCTAssertEqual(settings.profiles.profile(forApp: "com.apple.dt.Xcode").id, ProfileSettings.medicalID)
	}

	func testEffectiveSettingsLayProfileOverGlobalWithoutStoringIt() {
		var settings = HexSettings()
		settings.dictationMode = .literal
		settings.agentFormattingEnabled = false
		settings.activeLexiconPacks = ["medical-de"]
		settings.postProcessing.autoEnabled = true
		settings.profileModelSelections[.technical] = "parakeet-ultra-coreml"
		settings.selectedModel = "whisper"

		let coding = settings.effective(forApp: "com.apple.dt.Xcode")
		XCTAssertEqual(coding.asrProfile, .technical)
		XCTAssertEqual(coding.dictationMode, .normal)
		XCTAssertTrue(coding.agentFormattingEnabled)
		XCTAssertTrue(coding.textProcessing.spokenPunctuationInNormal)
		XCTAssertFalse(coding.postProcessing.autoEnabled)
		XCTAssertEqual(coding.selectedModel, "parakeet-ultra-coreml", "the domain remembers its model")
		XCTAssertEqual(coding.activeLexiconPacks, ["medical-de"], "nil packs keep the global selection")

		let mail = settings.effective(forApp: "com.apple.mail")
		XCTAssertEqual(mail.postProcessing.autoStyleID, AIStyleCatalog.emailID)
		XCTAssertEqual(mail.postProcessing.boxStyleID, AIStyleCatalog.emailID)
		XCTAssertTrue(mail.postProcessing.autoEnabled, "nil keeps the global switch")

		let general = settings.effective(forApp: "com.example.unknown")
		XCTAssertEqual(general.dictationMode, .literal)
		XCTAssertFalse(general.agentFormattingEnabled)
		// The stored settings are untouched.
		XCTAssertEqual(settings.dictationMode, .literal)
	}

	func testEachAppHasUniqueProfile() {
		var profiles = ProfileSettings()
		var mine = DictationProfile(id: "custom-notes", name: "Notes", symbol: "note", apps: [ProfileApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")])
		profiles.save(mine)
		XCTAssertEqual(profiles.profile(forApp: "com.apple.dt.Xcode").id, "custom-notes")
		XCTAssertFalse(profiles.profile(id: ProfileSettings.codingID).apps.contains { $0.bundleID == "com.apple.dt.Xcode" })
		mine.name = "Notizen"
		profiles.save(mine)
		XCTAssertEqual(profiles.profiles.filter { $0.id == "custom-notes" }.count, 1)
		profiles.manualProfileID = "custom-notes"
		profiles.delete("custom-notes")
		XCTAssertEqual(profiles.manualProfileID, ProfileSettings.generalID)
		profiles.delete(ProfileSettings.codingID)
		XCTAssertTrue(profiles.profiles.contains { $0.id == ProfileSettings.codingID }, "built-ins stay")
		profiles.restore(ProfileSettings.codingID)
		XCTAssertTrue(profiles.profile(id: ProfileSettings.codingID).apps.contains { $0.bundleID == "com.apple.dt.Xcode" })
	}

	func testPre26ManualProfileBecomesTheManualDictationProfile() throws {
		let old = try JSONDecoder().decode(HexSettings.self, from: Data(#"{"asrProfile":"technical"}"#.utf8))
		XCTAssertEqual(old.profiles.manualProfileID, ProfileSettings.codingID)
		XCTAssertEqual(old.profiles.profiles.count, ProfileSettings.builtIns.count)
		var custom = HexSettings()
		custom.profiles.switchByApp = false
		custom.profiles.save(DictationProfile(id: "x", name: "X", symbol: "star", mode: .streaming, contextUse: .appOnly))
		let roundTrip = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(custom))
		XCTAssertEqual(roundTrip.profiles, custom.profiles)
		// Unknown values fall back without losing the file.
		let odd = try JSONDecoder().decode(ProfileSettings.self, from: Data(#"{"switchByApp":"yes","profiles":[{"id":"y","mode":"telepathy","contextLevel":9}]}"#.utf8))
		XCTAssertTrue(odd.switchByApp)
		XCTAssertNil(odd.profile(id: "y").mode)
		XCTAssertEqual(odd.profiles.count, ProfileSettings.builtIns.count + 1, "missing built-ins come back")
	}
}
