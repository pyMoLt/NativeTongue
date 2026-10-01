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

  func testCanaryExperimentalCoreMLEntryIsPinned() throws {
		let entries = try LocalASRModelCatalog.load()
		let canary = try XCTUnwrap(entries.first { $0.internalName == "canary-1b-v2-int4-coreml" })
		XCTAssertEqual(canary.backend, .canaryFluidAudioCoreML)
		XCTAssertEqual(canary.revision?.count, 40)
		XCTAssertTrue(canary.experimental)
		XCTAssertTrue(canary.languages.contains("de"))
		XCTAssertFalse(entries.contains { $0.internalName.contains("mediform") || $0.backend.rawValue == "cohereFluidAudioCoreML" })
	}

	func testCohereMLXAndAppleSpeechAreSelectableWithHonestCapabilities() throws {
		let entries = try LocalASRModelCatalog.load()
		let cohere = try XCTUnwrap(entries.first { $0.internalName == CohereMLXASRClient.modelName })
		XCTAssertEqual(cohere.backend, .cohereMLX)
		XCTAssertEqual(cohere.revision, CohereMLXASRClient.revision)
		XCTAssertEqual(cohere.group, .experimental)
		XCTAssertEqual(cohere.literalRating, .limited)
		XCTAssertFalse(cohere.engineCapabilities.wordTimings)
		XCTAssertEqual(cohere.engineCapabilities.punctuationControl, .stripOnly)
		XCTAssertFalse(cohere.engineCapabilities.supportsAutoLanguage)

		let apple = try XCTUnwrap(entries.first { $0.internalName == AppleSpeechASRClient.modelName })
		XCTAssertEqual(apple.backend, .appleSpeechAnalyzer)
		XCTAssertEqual(apple.literalRating, .unverified)
		XCTAssertTrue(apple.engineCapabilities.wordTimings)
		XCTAssertTrue(apple.engineCapabilities.biasing.contains(.contextualStrings))
	}

	func testV2CatalogMetadataDistinguishesMeasuredAndUnmeasuredWhisperVariants() throws {
		let entries = try LocalASRModelCatalog.load()
		let turbo = try XCTUnwrap(entries.first { $0.internalName == "openai_whisper-large-v3-v20240930_turbo" })
		let compressed = try XCTUnwrap(entries.first { $0.internalName == "openai_whisper-large-v3-v20240930_turbo_632MB" })
		XCTAssertEqual(turbo.group, .recommended)
		XCTAssertEqual(turbo.literalRating, .reliable)
		XCTAssertEqual(turbo.recommendedFor, [.literal, .normal])
		XCTAssertEqual(turbo.engineCapabilities.punctuationControl, .decoderSuppression)
		XCTAssertEqual(compressed.literalRating, .unverified)
		XCTAssertTrue(entries.allSatisfy { !$0.languages.isEmpty })
	}

	func testCatalogStillDecodesOlderEntriesWithoutV2Fields() throws {
		let data = Data("""
		[{"displayName":"Legacy","internalName":"legacy","backend":"whisperKitCoreML","repository":"local","precision":"unknown","license":"unknown","languages":["de"],"size":"small","storageSize":"unknown","capabilities":{"wordTimings":true,"contextPrompt":false,"languageHint":true},"experimental":false}]
		""".utf8)
		let entry = try XCTUnwrap(LocalASRModelCatalog.decode(data).first)
		XCTAssertEqual(entry.group, .general)
		XCTAssertEqual(entry.literalRating, .unverified)
		XCTAssertEqual(entry.capabilities.punctuationControl, .stripOnly)
		XCTAssertTrue(entry.recommendedFor.isEmpty)
	}

	func testBundledBenchmarksMatchCatalogAndDistinguishDecoderModes() throws {
		let catalog = try LocalASRModelCatalog.load()
		let benchmarks = try ModelBenchmarkCatalog.load()
		XCTAssertEqual(benchmarks.speakerCount, 1)
		XCTAssertEqual(benchmarks.literalCommandReferenceCount, 14)
		XCTAssertEqual(benchmarks.terminologyReferenceCount, 47)
		XCTAssertTrue(benchmarks.measurements.allSatisfy { item in
			catalog.contains { $0.internalName == item.internalName }
				&& item.terminologyCorrect == item.medicalTermsCorrect + item.technicalTermsCorrect
		})
		let turbo = try XCTUnwrap(benchmarks.measurement(
			for: "openai_whisper-large-v3-v20240930_turbo",
			configuration: .punctuationSuppressed
		))
		XCTAssertEqual(turbo.literalCommandsRecognized, 14)
		XCTAssertEqual(turbo.automaticPunctuationCount, 0)
		XCTAssertNil(benchmarks.measurement(for: "apple-speechanalyzer-dictation", configuration: .natural))
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
