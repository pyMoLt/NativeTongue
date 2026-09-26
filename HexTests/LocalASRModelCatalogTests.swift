import Foundation
import XCTest
import HexCore

@testable import Hex

final class LocalASRModelCatalogTests: XCTestCase {
  func testBundledCatalogHasUniqueIdentifiersAndExplicitBackends() throws {
    let entries = try LocalASRModelCatalog.load()
    XCTAssertFalse(entries.isEmpty)
    XCTAssertEqual(Set(entries.map(\.internalName)).count, entries.count)
    XCTAssertTrue(entries.allSatisfy { !$0.repository.isEmpty && !$0.precision.isEmpty && !$0.license.isEmpty })
  }

  func testQwenEntriesArePinnedEightBitMLXModels() throws {
    let entries = try LocalASRModelCatalog.load().filter { $0.backend == .qwen3MLX }
    XCTAssertEqual(entries.count, 2)
    XCTAssertTrue(entries.allSatisfy { $0.revision?.count == 40 })
    XCTAssertTrue(entries.allSatisfy { $0.precision == "8-bit MLX" })
    XCTAssertTrue(entries.allSatisfy { $0.license == "Apache-2.0" })
    XCTAssertTrue(entries.allSatisfy { $0.capabilities.contextPrompt })
    XCTAssertTrue(entries.allSatisfy { !$0.capabilities.wordTimings })
  }

  func testTrueWhisperLargeAndTurboRemainDistinct() throws {
    let entries = try LocalASRModelCatalog.load()
    let large = try XCTUnwrap(entries.first { $0.internalName == "openai_whisper-large-v3" })
    let turbo = try XCTUnwrap(entries.first { $0.internalName == "openai_whisper-large-v3-v20240930_turbo" })
    let compressed = try XCTUnwrap(entries.first { $0.internalName == "openai_whisper-large-v3-v20240930_turbo_632MB" })

    XCTAssertEqual(large.precision, "FP16")
    XCTAssertEqual(turbo.precision, "FP16")
    XCTAssertEqual(compressed.precision, "4-bit compressed")
    XCTAssertNotEqual(large.internalName, turbo.internalName)
    XCTAssertNotEqual(turbo.internalName, compressed.internalName)
  }

  func testParakeetEntriesAreRevisionPinnedIncludingUltra() throws {
    let entries = try LocalASRModelCatalog.load().filter { $0.backend == .parakeetFluidAudioCoreML }
    XCTAssertEqual(entries.count, 3)
    XCTAssertTrue(entries.allSatisfy { $0.revision?.count == 40 })
    let ultra = try XCTUnwrap(entries.first { $0.internalName == ParakeetModel.multilingualUltra.identifier })
    XCTAssertTrue(ultra.experimental)
    XCTAssertEqual(ultra.repository, ParakeetModel.multilingualUltra.repository)
    XCTAssertEqual(ultra.revision, ParakeetModel.multilingualUltra.revision)
  }

  func testCanaryAndCohereExperimentalCoreMLEntriesArePinned() throws {
		let entries = try LocalASRModelCatalog.load()
		let canary = try XCTUnwrap(entries.first { $0.internalName == "canary-1b-v2-int4-coreml" })
		let cohere = try XCTUnwrap(entries.first { $0.internalName == "cohere-transcribe-q8-coreml" })
		XCTAssertEqual(canary.backend, .canaryFluidAudioCoreML)
		XCTAssertEqual(canary.revision?.count, 40)
		XCTAssertTrue(canary.experimental)
		XCTAssertTrue(canary.languages.contains("de"))
		XCTAssertEqual(cohere.backend, .cohereFluidAudioCoreML)
		XCTAssertEqual(cohere.revision?.count, 40)
		XCTAssertTrue(cohere.experimental)
		XCTAssertTrue(cohere.license.contains("conflicting"))
  }

  func testCanaryPromptUsesExplicitGermanAndEnglishLanguageTokens() throws {
		let vocabulary: [Int: String] = [
			16053: "▁", 7: "<|startofcontext|>", 4: "<|startoftranscript|>",
			16: "<|emo:undefined|>", 64: "<|en|>", 78: "<|de|>",
			5: "<|pnc|>", 9: "<|noitn|>", 11: "<|notimestamp|>", 13: "<|nodiarize|>",
		]
		XCTAssertEqual(try CanaryPromptFactory.prompt(language: "de", vocabulary: vocabulary), [16053, 7, 4, 16, 78, 78, 5, 9, 11, 13])
		XCTAssertEqual(try CanaryPromptFactory.prompt(language: "en", vocabulary: vocabulary), [16053, 7, 4, 16, 64, 64, 5, 9, 11, 13])
  }

	func testCanaryPromptRejectsAutomaticOrUnsupportedLanguage() {
		let vocabulary = [16053: "▁"]
		XCTAssertThrowsError(try CanaryPromptFactory.prompt(language: nil, vocabulary: vocabulary))
		XCTAssertThrowsError(try CanaryPromptFactory.prompt(language: "it", vocabulary: vocabulary))
	}

	func testMediformMedicalGermanCheckpointIsExplicitlyPinnedAndExperimental() throws {
		let mediform = try XCTUnwrap(LocalASRModelCatalog.load().first {
			$0.internalName == MediformInstallationValidator.modelName
		})
		XCTAssertEqual(mediform.backend, .mediformParakeetCoreML)
		XCTAssertEqual(mediform.repository, MediformInstallationValidator.repository)
		XCTAssertEqual(mediform.revision, MediformInstallationValidator.revision)
		XCTAssertEqual(mediform.precision, "FP16 encoder · FluidAudio-compatible Core ML")
		XCTAssertEqual(MediformInstallationValidator.archiveSize, 1_128_173_433)
		XCTAssertEqual(MediformInstallationValidator.archiveSHA256.count, 64)
		XCTAssertTrue(mediform.experimental)
		XCTAssertEqual(mediform.languages.first, "de")
	}

	func testMediformInstallManifestRequiresAllCoreMLComponents() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalASR-MediformTest-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

		for name in MediformInstallationValidator.requiredComponents {
			let url = root.appendingPathComponent(name)
			if name.hasSuffix(".mlmodelc") {
				try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
				try Data([0x01]).write(to: url.appendingPathComponent("model.bin"))
			} else {
				try Data("vocabulary".utf8).write(to: url)
			}
		}

		try MediformInstallationValidator.createManifest(at: root)
		XCTAssertTrue(MediformInstallationValidator.isInstalled(at: root))

		try FileManager.default.removeItem(at: root.appendingPathComponent("JointDecisionv3.mlmodelc"))
		XCTAssertFalse(MediformInstallationValidator.isInstalled(at: root))
	}

	func testMediformRejectsEnglishBeforeLoadingGermanOnlyWeights() async throws {
		let mediform = try XCTUnwrap(LocalASRModelCatalog.load().first {
			$0.internalName == MediformInstallationValidator.modelName
		})
		let adapter = AdditionalFluidAudioASRClient()
		do {
			try await adapter.validateLanguage(mediform, language: "en")
			XCTFail("The German-only medical model must reject English before model loading.")
		} catch {
			XCTAssertTrue(error.localizedDescription.contains("de"))
		}
		try await adapter.validateLanguage(mediform, language: "de")
	}

	func testOmiMedicalEnglishCheckpointHasPinnedFP16CoreMLArtifacts() throws {
		let omi = try XCTUnwrap(LocalASRModelCatalog.load().first {
			$0.internalName == OmiMedicalInstallationValidator.modelName
		})
		XCTAssertEqual(omi.backend, .omiMedicalParakeetCoreML)
		XCTAssertEqual(omi.repository, OmiMedicalInstallationValidator.repository)
		XCTAssertEqual(omi.revision, OmiMedicalInstallationValidator.revision)
		XCTAssertEqual(omi.precision, "FP16 MLProgram · FluidAudio Parakeet-v2 compatible")
		XCTAssertEqual(OmiMedicalInstallationValidator.weightSHA256.count, 4)
		XCTAssertTrue(OmiMedicalInstallationValidator.weightSHA256.values.allSatisfy { $0.count == 64 })
		XCTAssertEqual(OmiMedicalInstallationValidator.requiredDownloadGlobs.last, "parakeet_vocab.json")
		XCTAssertTrue(omi.experimental)
		XCTAssertEqual(omi.languages.first, "en")
	}

	func testOmiInstallManifestRequiresAllV2CoreMLComponentsAndWeightFiles() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalASR-OmiMedTest-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

		for name in OmiMedicalInstallationValidator.requiredComponents {
			let url = root.appendingPathComponent(name)
			if name.hasSuffix(".mlmodelc") {
				try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
				try Data([0x01]).write(to: url.appendingPathComponent("model.bin"))
			} else {
				try Data("vocabulary".utf8).write(to: url)
			}
		}
		for relativePath in OmiMedicalInstallationValidator.weightSHA256.keys {
			let weightURL = root.appendingPathComponent(relativePath)
			try FileManager.default.createDirectory(at: weightURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data([0x01]).write(to: weightURL)
		}
		XCTAssertThrowsError(try OmiMedicalInstallationValidator.verifyPinnedWeights(at: root))

		try OmiMedicalInstallationValidator.createManifest(at: root)
		XCTAssertTrue(OmiMedicalInstallationValidator.isInstalled(at: root))
		try FileManager.default.removeItem(at: root.appendingPathComponent("JointDecision.mlmodelc"))
		XCTAssertFalse(OmiMedicalInstallationValidator.isInstalled(at: root))
	}

	func testOmiMedicalModelRejectsGermanBeforeLoadingEnglishOnlyWeights() async throws {
		let omi = try XCTUnwrap(LocalASRModelCatalog.load().first {
			$0.internalName == OmiMedicalInstallationValidator.modelName
		})
		let adapter = AdditionalFluidAudioASRClient()
		do {
			try await adapter.validateLanguage(omi, language: "de")
			XCTFail("The English-only medical model must reject German before model loading.")
		} catch {
			XCTAssertTrue(error.localizedDescription.contains("en"))
		}
		try await adapter.validateLanguage(omi, language: "en")
	}
}
