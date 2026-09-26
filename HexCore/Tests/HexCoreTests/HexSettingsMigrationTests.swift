import XCTest
@testable import HexCore

final class HexSettingsMigrationTests: XCTestCase {
	func testV1FixtureMigratesToCurrentDefaults() throws {
		let data = try loadFixture(named: "v1")
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.recordingAudioBehavior, .pauseMedia, "Legacy pauseMediaOnRecord bool should map to pauseMedia behavior")
		XCTAssertEqual(decoded.soundEffectsEnabled, false)
		XCTAssertEqual(decoded.soundEffectsVolume, HexSettings.baseSoundEffectsVolume)
		XCTAssertEqual(decoded.openOnLogin, true)
		XCTAssertEqual(decoded.showDockIcon, false)
		XCTAssertEqual(decoded.selectedModel, "whisper-large-v3")
		XCTAssertEqual(decoded.idleUnloadMinutes, 10)
		XCTAssertEqual(decoded.asrProfile, .general)
		XCTAssertEqual(decoded.profileModelSelections[.general], "whisper-large-v3")
		XCTAssertEqual(decoded.spokenCommandPauseSeconds, 0.45)
		XCTAssertEqual(decoded.useClipboardPaste, false)
		XCTAssertEqual(decoded.preventSystemSleep, true)
		XCTAssertEqual(decoded.minimumKeyTime, 0.25)
		XCTAssertEqual(decoded.copyToClipboard, true)
		XCTAssertTrue(decoded.superFastModeEnabled)
		XCTAssertEqual(decoded.useDoubleTapOnly, true)
		XCTAssertEqual(decoded.doubleTapLockEnabled, true)
		XCTAssertEqual(decoded.outputLanguage, "en")
		XCTAssertEqual(decoded.selectedMicrophoneID, "builtin:mic")
		XCTAssertEqual(decoded.saveTranscriptionHistory, false)
		XCTAssertEqual(decoded.maxHistoryEntries, 10)
		XCTAssertEqual(decoded.hasCompletedModelBootstrap, true)
		XCTAssertEqual(decoded.hasCompletedStorageMigration, true)
		XCTAssertFalse(decoded.lowercaseTranscripts)
		XCTAssertFalse(decoded.removePunctuation)
	}

	func testEncodeDecodeRoundTripPreservesDefaults() throws {
		let settings = HexSettings()
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertEqual(decoded, settings)
	}

	func testNewSettingsEnableSuperFastModeByDefault() {
		XCTAssertTrue(HexSettings().superFastModeEnabled)
	}

	func testNewSettingsDisableTranscriptionHistoryByDefault() {
		XCTAssertFalse(HexSettings().saveTranscriptionHistory)
	}

	func testNewSettingsDoNotChooseAnASRModelBeforeTheUserDoes() {
		XCTAssertTrue(HexSettings().selectedModel.isEmpty)
	}

	func testIdleUnloadSettingMigratesAndRejectsUnsupportedValues() throws {
		let legacy = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		XCTAssertEqual(legacy.idleUnloadMinutes, 10)
		let invalid = try JSONDecoder().decode(HexSettings.self, from: Data("{\"idleUnloadMinutes\":7}".utf8))
		XCTAssertEqual(invalid.idleUnloadMinutes, 10)
		let disabled = try JSONDecoder().decode(HexSettings.self, from: Data("{\"idleUnloadMinutes\":0}".utf8))
		XCTAssertEqual(disabled.idleUnloadMinutes, 0)
	}

	func testDictationModeDefaultsToNormalAndPersists() throws {
		var settings = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		XCTAssertEqual(settings.dictationMode, .normal)

		settings.dictationMode = .literal
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))
		XCTAssertEqual(decoded.dictationMode, .literal)
	}

	func testASRProfileVocabularyAndPausePersist() throws {
		var settings = HexSettings()
		settings.asrProfile = .medical
		settings.profileModelSelections[.medical] = "medical-model"
		settings.spokenCommandPauseSeconds = 0.6
		settings.medicalVocabulary = "Metoprolol\nBisoprolol"

		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))
		XCTAssertEqual(decoded.asrProfile, .medical)
		XCTAssertEqual(decoded.profileModelSelections[.medical], "medical-model")
		XCTAssertEqual(decoded.spokenCommandPauseSeconds, 0.6)
		XCTAssertEqual(decoded.medicalVocabulary, "Metoprolol\nBisoprolol")
	}

	func testSpokenCommandPauseIsClampedOnDecode() throws {
		let low = try JSONDecoder().decode(HexSettings.self, from: Data("{\"spokenCommandPauseSeconds\":0.01}".utf8))
		let high = try JSONDecoder().decode(HexSettings.self, from: Data("{\"spokenCommandPauseSeconds\":4}".utf8))

		XCTAssertEqual(low.spokenCommandPauseSeconds, 0.25)
		XCTAssertEqual(high.spokenCommandPauseSeconds, 1.0)
	}

	func testTerminologyContextIsDeduplicatedAndBounded() {
		let repeated = Array(repeating: "Apixaban", count: 100).joined(separator: "\n")
		let prompt = ASRTerminologyContext.prompt(profile: .medical, additionalTerms: repeated)

		XCTAssertNotNil(prompt)
		XCTAssertLessThanOrEqual(prompt?.count ?? .max, ASRTerminologyContext.maximumCharacters)
		XCTAssertEqual(prompt?.components(separatedBy: "Apixaban").count, 2)
	}

	func testInitNormalizesDoubleTapOnlyWhenLockDisabled() {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)

		XCTAssertFalse(settings.useDoubleTapOnly)
		XCTAssertFalse(settings.doubleTapLockEnabled)
	}

	func testDecodeNormalizesDoubleTapOnlyWhenLockDisabled() throws {
		let payload = "{\"useDoubleTapOnly\":true,\"doubleTapLockEnabled\":false}"
		guard let data = payload.data(using: .utf8) else {
			XCTFail("Failed to encode JSON payload")
			return
		}

		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertFalse(decoded.useDoubleTapOnly)
		XCTAssertFalse(decoded.doubleTapLockEnabled)
	}

	func testEncodeDecodeRoundTripPreservesNormalizedDoubleTapValues() throws {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertFalse(settings.useDoubleTapOnly)
		XCTAssertFalse(decoded.useDoubleTapOnly)
		XCTAssertEqual(decoded, settings)
	}

	private func loadFixture(named name: String) throws -> Data {
		guard let url = Bundle.module.url(
			forResource: name,
			withExtension: "json",
			subdirectory: "Fixtures/HexSettings"
		) else {
			XCTFail("Missing fixture \(name).json")
			throw NSError(domain: "Fixture", code: 0)
		}
		return try Data(contentsOf: url)
	}
}
