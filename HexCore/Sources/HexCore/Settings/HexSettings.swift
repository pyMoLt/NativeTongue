import Foundation

public enum RecordingAudioBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case pauseMedia
	case mute
	case doNothing
}

/// User-configurable settings saved to disk.
public struct HexSettings: Codable, Equatable, Sendable {
	public static let defaultPasteLastTranscriptHotkey = HotKey(key: .v, modifiers: [.option, .shift])
	public static let baseSoundEffectsVolume: Double = HexCoreConstants.baseSoundEffectsVolume
	public static let defaultWordRemovals: [WordRemoval] = [
		.init(pattern: "uh+"),
		.init(pattern: "um+"),
		.init(pattern: "er+"),
		.init(pattern: "hm+")
	]

	public static var defaultPasteLastTranscriptHotkeyDescription: String {
		let modifiers = defaultPasteLastTranscriptHotkey.modifiers.sorted.map { $0.stringValue }.joined()
		let key = defaultPasteLastTranscriptHotkey.key?.toString ?? ""
		return modifiers + key
	}

	public var soundEffectsEnabled: Bool
	public var soundEffectsVolume: Double
	public var hotkey: HotKey
	public var openOnLogin: Bool
	public var showDockIcon: Bool
	public var selectedModel: String
	public var idleUnloadMinutes: Int
	public var dictationMode: DictationMode
	public var asrProfile: ASRProfile
	public var profileModelSelections: [ASRProfile: String]
	public var spokenCommandPauseSeconds: Double
	public var generalVocabulary: String
	public var medicalVocabulary: String
	public var technicalVocabulary: String
	public var useClipboardPaste: Bool
	public var preventSystemSleep: Bool
	public var recordingAudioBehavior: RecordingAudioBehavior
	public var minimumKeyTime: Double
	public var copyToClipboard: Bool
	public var superFastModeEnabled: Bool
	public var useDoubleTapOnly: Bool
	public var doubleTapLockEnabled: Bool
	/// „Hold to talk, tap to toggle“ (plan B9): a short tap starts a hands-free
	/// recording, the next press stops it; holding works as push-to-talk.
	public var hotkeyTapToggle: Bool
	/// Whisper: decode speech again that the full-recording pass skipped
	/// (`WhisperGapFiller`), in Normal and Literal mode. On by default.
	public var whisperGapFill: Bool
	public var outputLanguage: String?
	public var selectedMicrophoneID: String?
	public var saveTranscriptionHistory: Bool
	public var maxHistoryEntries: Int?
	public var pasteLastTranscriptHotkey: HotKey?
	/// Command Mode shortcut (C3); nil = not set.
	public var commandModeHotkey: HotKey?
	public var hasCompletedModelBootstrap: Bool
	public var hasCompletedStorageMigration: Bool
	public var wordRemovalsEnabled: Bool
	public var wordRemovals: [WordRemoval]
	public var wordRemappings: [WordRemapping]
	public var lowercaseTranscripts: Bool
	public var removePunctuation: Bool
	public var autoReplaceTermsLiteral: Bool
	public var activeLexiconPacks: [String]
	public var hasMigratedLexicon: Bool
	public var dictationBoxEnabledNormal: Bool
	public var dictationBoxEnabledLiteral: Bool
	public var boxFontName: String
	public var boxFontSize: Double
	public var boxOutputFormat: OutputFormat
	public var englishCommandsEnabled: Bool
	public var agentFormattingEnabled: Bool
	public var numberFormattingEnabled: Bool
	public var hasCompletedV2Onboarding: Bool
	/// Per-model „Kontext-Biasing (experimentell)“; missing = model default.
	public var modelBiasing: [String: Bool]
	/// Model for literal mode; empty = same as `selectedModel` (plan 5.12).
	public var literalModel: String
	/// Optional local, content-free metrics file (About → Diagnostics).
	public var diagnosticsEnabled: Bool
	/// Optional local AI post-processing (V2.5; off by default).
	public var postProcessing: PostProcessingSettings
	/// Streaming mode (V2.5; used when `dictationMode == .streaming`).
	public var streaming: StreamingSettings
	/// Look of the interface (2.6 "Flow": accent, glass, background, motion).
	public var appearance: AppearanceSettings
	/// Self-corrections, spoken punctuation in Normal, learning (2.6 stage B).
	public var textProcessing: TextProcessingSettings
	/// Dictation profiles and switching by app (2.6, C2).
	public var profiles: ProfileSettings

	/// Catalog entries removed in 3.2 → the model that replaces them.
	public static let retiredModels: [String: String] = [
		"openai_whisper-large-v3-v20240930": "openai_whisper-large-v3-v20240930_turbo",
		"openai_whisper-large-v3-v20240930_turbo_632MB": "openai_whisper-large-v3-v20240930_turbo",
	]

	private mutating func normalizeSettings() {
		func replacing(_ model: String) -> String { Self.retiredModels[model] ?? model }
		selectedModel = replacing(selectedModel)
		literalModel = replacing(literalModel)
		profileModelSelections = profileModelSelections.mapValues(replacing)
		if !doubleTapLockEnabled {
			useDoubleTapOnly = false
		}
		spokenCommandPauseSeconds = min(max(spokenCommandPauseSeconds, 0.25), 1.2)
		if ![0, 2, 5, 10, 30].contains(idleUnloadMinutes) { idleUnloadMinutes = 10 }
		boxFontSize = min(max(boxFontSize, 11), 28)
		if !selectedModel.isEmpty, profileModelSelections[asrProfile] == nil {
			profileModelSelections[asrProfile] = selectedModel
		}
	}

	public init(
		soundEffectsEnabled: Bool = true,
		soundEffectsVolume: Double = HexSettings.baseSoundEffectsVolume,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = "",
		idleUnloadMinutes: Int = 10,
		dictationMode: DictationMode = .normal,
		asrProfile: ASRProfile = .general,
		profileModelSelections: [ASRProfile: String] = [:],
		spokenCommandPauseSeconds: Double = 0.45,
		generalVocabulary: String = "",
		medicalVocabulary: String = "",
		technicalVocabulary: String = "",
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		recordingAudioBehavior: RecordingAudioBehavior = .doNothing,
		minimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime,
		copyToClipboard: Bool = false,
		superFastModeEnabled: Bool = true,
		useDoubleTapOnly: Bool = false,
		doubleTapLockEnabled: Bool = true,
		hotkeyTapToggle: Bool = false,
		whisperGapFill: Bool = true,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
		saveTranscriptionHistory: Bool = false,
		maxHistoryEntries: Int? = nil,
		pasteLastTranscriptHotkey: HotKey? = HexSettings.defaultPasteLastTranscriptHotkey,
		hasCompletedModelBootstrap: Bool = false,
		hasCompletedStorageMigration: Bool = false,
		wordRemovalsEnabled: Bool = false,
		wordRemovals: [WordRemoval] = HexSettings.defaultWordRemovals,
		wordRemappings: [WordRemapping] = [],
		lowercaseTranscripts: Bool = false,
		removePunctuation: Bool = false,
		autoReplaceTermsLiteral: Bool = true,
		activeLexiconPacks: [String] = [],
		hasMigratedLexicon: Bool = false,
		dictationBoxEnabledNormal: Bool = false,
		dictationBoxEnabledLiteral: Bool = true,
		boxFontName: String = "",
		boxFontSize: Double = 15,
		boxOutputFormat: OutputFormat = .richText,
		englishCommandsEnabled: Bool = true,
		agentFormattingEnabled: Bool = true,
		numberFormattingEnabled: Bool = true,
		hasCompletedV2Onboarding: Bool = false,
		modelBiasing: [String: Bool] = [:],
		literalModel: String = "",
		diagnosticsEnabled: Bool = false,
		postProcessing: PostProcessingSettings = PostProcessingSettings(),
		streaming: StreamingSettings = StreamingSettings(),
		appearance: AppearanceSettings = AppearanceSettings(),
		textProcessing: TextProcessingSettings = TextProcessingSettings(),
		profiles: ProfileSettings = ProfileSettings(),
		commandModeHotkey: HotKey? = nil
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.soundEffectsVolume = soundEffectsVolume
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.idleUnloadMinutes = idleUnloadMinutes
		self.dictationMode = dictationMode
		self.asrProfile = asrProfile
		self.profileModelSelections = profileModelSelections
		self.spokenCommandPauseSeconds = min(max(spokenCommandPauseSeconds, 0.25), 1.2)
		self.generalVocabulary = generalVocabulary
		self.medicalVocabulary = medicalVocabulary
		self.technicalVocabulary = technicalVocabulary
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.recordingAudioBehavior = recordingAudioBehavior
		self.minimumKeyTime = minimumKeyTime
		self.copyToClipboard = copyToClipboard
		self.superFastModeEnabled = superFastModeEnabled
		self.useDoubleTapOnly = useDoubleTapOnly
		self.doubleTapLockEnabled = doubleTapLockEnabled
		self.hotkeyTapToggle = hotkeyTapToggle
		self.whisperGapFill = whisperGapFill
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
		self.saveTranscriptionHistory = saveTranscriptionHistory
		self.maxHistoryEntries = maxHistoryEntries
		self.pasteLastTranscriptHotkey = pasteLastTranscriptHotkey
		self.hasCompletedModelBootstrap = hasCompletedModelBootstrap
		self.hasCompletedStorageMigration = hasCompletedStorageMigration
		self.wordRemovalsEnabled = wordRemovalsEnabled
		self.wordRemovals = wordRemovals
		self.wordRemappings = wordRemappings
		self.lowercaseTranscripts = lowercaseTranscripts
		self.removePunctuation = removePunctuation
		self.autoReplaceTermsLiteral = autoReplaceTermsLiteral
		self.activeLexiconPacks = activeLexiconPacks
		self.hasMigratedLexicon = hasMigratedLexicon
		self.dictationBoxEnabledNormal = dictationBoxEnabledNormal
		self.dictationBoxEnabledLiteral = dictationBoxEnabledLiteral
		self.boxFontName = boxFontName
		self.boxFontSize = boxFontSize
		self.boxOutputFormat = boxOutputFormat
		self.englishCommandsEnabled = englishCommandsEnabled
		self.agentFormattingEnabled = agentFormattingEnabled
		self.numberFormattingEnabled = numberFormattingEnabled
		self.hasCompletedV2Onboarding = hasCompletedV2Onboarding
		self.modelBiasing = modelBiasing
		self.literalModel = literalModel
		self.diagnosticsEnabled = diagnosticsEnabled
		self.postProcessing = postProcessing
		self.streaming = streaming
		self.appearance = appearance
		self.textProcessing = textProcessing
		self.profiles = profiles
		self.commandModeHotkey = commandModeHotkey
		normalizeSettings()
	}

	public init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.decode(into: &self, from: container)
		}
		// Before 2.6 the profile was chosen by hand only.
		if !container.contains(.profiles) {
			profiles.manualProfileID = switch asrProfile {
			case .general: ProfileSettings.generalID
			case .medical: ProfileSettings.medicalID
			case .technical: ProfileSettings.codingID
			}
		}
		normalizeSettings()
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.encode(self, into: &container)
		}
	}
}

public extension HexSettings {
	var activeVocabulary: String {
		switch asrProfile {
		case .general: generalVocabulary
		case .medical: medicalVocabulary
		case .technical: technicalVocabulary
		}
	}

	/// Lexicon terms are sent as model context only where this is enabled.
	/// Default on for Qwen/Apple (robust, with leak guard), off for Whisper
	/// (prompts dropped passages in the 2026-09-26 benchmark) and others.
	func isBiasingEnabled(for model: String) -> Bool {
		if let value = modelBiasing[model] { return value }
		return model.hasPrefix("qwen3-asr") || model.hasPrefix("apple-speechanalyzer")
	}

	/// Model used for a dictation in `mode` (literal may use its own model).
	func model(for mode: DictationMode) -> String {
		switch mode {
		case .literal: literalModel.isEmpty ? selectedModel : literalModel
		case .normal: selectedModel
		case .streaming: streaming.model.isEmpty ? StreamingSettings.recommendedModel : streaming.model
		}
	}

	/// Model for the currently selected mode.
	var activeModel: String { model(for: dictationMode) }

	func dictationBoxEnabled(for mode: DictationMode) -> Bool {
		switch mode {
		case .literal: dictationBoxEnabledLiteral
		case .normal: dictationBoxEnabledNormal
		case .streaming: false
		}
	}

	var activeTerminologyPrompt: String? {
		ASRTerminologyContext.prompt(profile: asrProfile, additionalTerms: activeVocabulary)
	}
}

// MARK: - Schema

private enum HexSettingKey: String, CodingKey, CaseIterable {
	case soundEffectsEnabled
	case soundEffectsVolume
	case hotkey
	case openOnLogin
	case showDockIcon
	case selectedModel
	case idleUnloadMinutes
	case dictationMode
	case asrProfile
	case profileModelSelections
	case spokenCommandPauseSeconds
	case generalVocabulary
	case medicalVocabulary
	case technicalVocabulary
	case useClipboardPaste
	case preventSystemSleep
	case recordingAudioBehavior
	case pauseMediaOnRecord // Legacy
	case minimumKeyTime
	case copyToClipboard
	case superFastModeEnabled
	case useDoubleTapOnly
	case doubleTapLockEnabled
	case outputLanguage
	case selectedMicrophoneID
	case saveTranscriptionHistory
	case maxHistoryEntries
	case pasteLastTranscriptHotkey
	case hasCompletedModelBootstrap
	case hasCompletedStorageMigration
	case wordRemovalsEnabled
	case wordRemovals
	case wordRemappings
	case lowercaseTranscripts
	case removePunctuation
	case autoReplaceTermsLiteral
	case activeLexiconPacks
	case hasMigratedLexicon
	case dictationBoxEnabledNormal
	case dictationBoxEnabledLiteral
	case boxFontName
	case boxFontSize
	case boxOutputFormat
	case englishCommandsEnabled
	case agentFormattingEnabled
	case numberFormattingEnabled
	case hasCompletedV2Onboarding
	case modelBiasing
	case literalModel
	case diagnosticsEnabled
	case postProcessing
	case streaming
	case appearance
	case textProcessing
	case profiles
	case commandModeHotkey
	case hotkeyTapToggle
	case whisperGapFill
}

private struct SettingsField<Value: Codable & Sendable> {
	let key: HexSettingKey
	let keyPath: WritableKeyPath<HexSettings, Value>
	let defaultValue: Value
	let decodeStrategy: (KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value
	let encodeStrategy: (inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void

	init(
		_ key: HexSettingKey,
		keyPath: WritableKeyPath<HexSettings, Value>,
		default defaultValue: Value,
		decode: ((KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value)? = nil,
		encode: ((inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void)? = nil
	) {
		self.key = key
		self.keyPath = keyPath
		self.defaultValue = defaultValue
		self.decodeStrategy = decode ?? { container, key, defaultValue in
			try container.decodeIfPresent(Value.self, forKey: key) ?? defaultValue
		}
		self.encodeStrategy = encode ?? { container, key, value in
			try container.encode(value, forKey: key)
		}
	}

	func eraseToAny() -> AnySettingsField {
		AnySettingsField(
			key: key,
			decode: { container, settings in
				let value = try decodeStrategy(container, key, defaultValue)
				settings[keyPath: keyPath] = value
			},
			encode: { settings, container in
				let value = settings[keyPath: keyPath]
				try encodeStrategy(&container, key, value)
			}
		)
	}
}

private struct AnySettingsField {
	let key: HexSettingKey
	let decode: (KeyedDecodingContainer<HexSettingKey>, inout HexSettings) throws -> Void
	let encode: (HexSettings, inout KeyedEncodingContainer<HexSettingKey>) throws -> Void

	func decode(into settings: inout HexSettings, from container: KeyedDecodingContainer<HexSettingKey>) throws {
		try decode(container, &settings)
	}

	func encode(_ settings: HexSettings, into container: inout KeyedEncodingContainer<HexSettingKey>) throws {
		try encode(settings, &container)
	}
}

private enum HexSettingsSchema {
	static let defaults = HexSettings()

	nonisolated(unsafe) static let fields: [AnySettingsField] = [
		SettingsField(.soundEffectsEnabled, keyPath: \.soundEffectsEnabled, default: defaults.soundEffectsEnabled).eraseToAny(),
		SettingsField(.soundEffectsVolume, keyPath: \.soundEffectsVolume, default: defaults.soundEffectsVolume).eraseToAny(),
		SettingsField(.hotkey, keyPath: \.hotkey, default: defaults.hotkey).eraseToAny(),
		SettingsField(.openOnLogin, keyPath: \.openOnLogin, default: defaults.openOnLogin).eraseToAny(),
		SettingsField(.showDockIcon, keyPath: \.showDockIcon, default: defaults.showDockIcon).eraseToAny(),
		SettingsField(.selectedModel, keyPath: \.selectedModel, default: defaults.selectedModel).eraseToAny(),
		SettingsField(.idleUnloadMinutes, keyPath: \.idleUnloadMinutes, default: defaults.idleUnloadMinutes).eraseToAny(),
		SettingsField(.dictationMode, keyPath: \.dictationMode, default: defaults.dictationMode).eraseToAny(),
		SettingsField(.asrProfile, keyPath: \.asrProfile, default: defaults.asrProfile).eraseToAny(),
		SettingsField(.profileModelSelections, keyPath: \.profileModelSelections, default: defaults.profileModelSelections).eraseToAny(),
		SettingsField(.spokenCommandPauseSeconds, keyPath: \.spokenCommandPauseSeconds, default: defaults.spokenCommandPauseSeconds).eraseToAny(),
		SettingsField(.generalVocabulary, keyPath: \.generalVocabulary, default: defaults.generalVocabulary).eraseToAny(),
		SettingsField(.medicalVocabulary, keyPath: \.medicalVocabulary, default: defaults.medicalVocabulary).eraseToAny(),
		SettingsField(.technicalVocabulary, keyPath: \.technicalVocabulary, default: defaults.technicalVocabulary).eraseToAny(),
		SettingsField(.useClipboardPaste, keyPath: \.useClipboardPaste, default: defaults.useClipboardPaste).eraseToAny(),
		SettingsField(.preventSystemSleep, keyPath: \.preventSystemSleep, default: defaults.preventSystemSleep).eraseToAny(),
		SettingsField(
			.recordingAudioBehavior,
			keyPath: \.recordingAudioBehavior,
			default: defaults.recordingAudioBehavior,
			decode: { container, key, defaultValue in
				if let value = try container.decodeIfPresent(RecordingAudioBehavior.self, forKey: key) {
					return value
				}
				if let legacyPause = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) {
					return legacyPause ? .pauseMedia : .doNothing
				}
				return defaultValue
			}
		).eraseToAny(),
		SettingsField(.minimumKeyTime, keyPath: \.minimumKeyTime, default: defaults.minimumKeyTime).eraseToAny(),
		SettingsField(.copyToClipboard, keyPath: \.copyToClipboard, default: defaults.copyToClipboard).eraseToAny(),
		SettingsField(.superFastModeEnabled, keyPath: \.superFastModeEnabled, default: defaults.superFastModeEnabled).eraseToAny(),
		SettingsField(.useDoubleTapOnly, keyPath: \.useDoubleTapOnly, default: defaults.useDoubleTapOnly).eraseToAny(),
		SettingsField(.doubleTapLockEnabled, keyPath: \.doubleTapLockEnabled, default: defaults.doubleTapLockEnabled).eraseToAny(),
		SettingsField(
			.outputLanguage,
			keyPath: \.outputLanguage,
			default: defaults.outputLanguage,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.selectedMicrophoneID,
			keyPath: \.selectedMicrophoneID,
			default: defaults.selectedMicrophoneID,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.saveTranscriptionHistory, keyPath: \.saveTranscriptionHistory, default: defaults.saveTranscriptionHistory).eraseToAny(),
		SettingsField(
			.maxHistoryEntries,
			keyPath: \.maxHistoryEntries,
			default: defaults.maxHistoryEntries,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.pasteLastTranscriptHotkey,
			keyPath: \.pasteLastTranscriptHotkey,
			default: defaults.pasteLastTranscriptHotkey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.hasCompletedModelBootstrap, keyPath: \.hasCompletedModelBootstrap, default: defaults.hasCompletedModelBootstrap).eraseToAny(),
		SettingsField(.hasCompletedStorageMigration, keyPath: \.hasCompletedStorageMigration, default: defaults.hasCompletedStorageMigration).eraseToAny(),
		SettingsField(.wordRemovalsEnabled, keyPath: \.wordRemovalsEnabled, default: defaults.wordRemovalsEnabled).eraseToAny(),
		SettingsField(
			.wordRemovals,
			keyPath: \.wordRemovals,
			default: defaults.wordRemovals
		).eraseToAny(),
		SettingsField(
			.wordRemappings,
			keyPath: \.wordRemappings,
			default: defaults.wordRemappings
		).eraseToAny(),
		SettingsField(.lowercaseTranscripts, keyPath: \.lowercaseTranscripts, default: defaults.lowercaseTranscripts).eraseToAny(),
		SettingsField(.removePunctuation, keyPath: \.removePunctuation, default: defaults.removePunctuation).eraseToAny(),
		SettingsField(.autoReplaceTermsLiteral, keyPath: \.autoReplaceTermsLiteral, default: defaults.autoReplaceTermsLiteral).eraseToAny(),
		SettingsField(.activeLexiconPacks, keyPath: \.activeLexiconPacks, default: defaults.activeLexiconPacks).eraseToAny(),
		SettingsField(.hasMigratedLexicon, keyPath: \.hasMigratedLexicon, default: defaults.hasMigratedLexicon).eraseToAny(),
		SettingsField(.dictationBoxEnabledNormal, keyPath: \.dictationBoxEnabledNormal, default: defaults.dictationBoxEnabledNormal).eraseToAny(),
		SettingsField(.dictationBoxEnabledLiteral, keyPath: \.dictationBoxEnabledLiteral, default: defaults.dictationBoxEnabledLiteral).eraseToAny(),
		SettingsField(.boxFontName, keyPath: \.boxFontName, default: defaults.boxFontName).eraseToAny(),
		SettingsField(.boxFontSize, keyPath: \.boxFontSize, default: defaults.boxFontSize).eraseToAny(),
		SettingsField(.boxOutputFormat, keyPath: \.boxOutputFormat, default: defaults.boxOutputFormat).eraseToAny(),
		SettingsField(.englishCommandsEnabled, keyPath: \.englishCommandsEnabled, default: defaults.englishCommandsEnabled).eraseToAny(),
		SettingsField(.agentFormattingEnabled, keyPath: \.agentFormattingEnabled, default: defaults.agentFormattingEnabled).eraseToAny(),
		SettingsField(.numberFormattingEnabled, keyPath: \.numberFormattingEnabled, default: defaults.numberFormattingEnabled).eraseToAny(),
		SettingsField(.hasCompletedV2Onboarding, keyPath: \.hasCompletedV2Onboarding, default: defaults.hasCompletedV2Onboarding).eraseToAny(),
		SettingsField(.modelBiasing, keyPath: \.modelBiasing, default: defaults.modelBiasing).eraseToAny(),
		SettingsField(.literalModel, keyPath: \.literalModel, default: defaults.literalModel).eraseToAny(),
		SettingsField(.diagnosticsEnabled, keyPath: \.diagnosticsEnabled, default: defaults.diagnosticsEnabled).eraseToAny(),
		SettingsField(.postProcessing, keyPath: \.postProcessing, default: defaults.postProcessing).eraseToAny(),
		SettingsField(.streaming, keyPath: \.streaming, default: defaults.streaming).eraseToAny(),
		SettingsField(.appearance, keyPath: \.appearance, default: defaults.appearance).eraseToAny(),
		SettingsField(.textProcessing, keyPath: \.textProcessing, default: defaults.textProcessing).eraseToAny(),
		SettingsField(.profiles, keyPath: \.profiles, default: defaults.profiles).eraseToAny(),
		SettingsField(
			.commandModeHotkey,
			keyPath: \.commandModeHotkey,
			default: defaults.commandModeHotkey,
			decode: { container, key, fallback in (try? container.decodeIfPresent(HotKey.self, forKey: key)) ?? fallback },
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(.hotkeyTapToggle, keyPath: \.hotkeyTapToggle, default: defaults.hotkeyTapToggle,
		              decode: { container, key, value in (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? value }).eraseToAny(),
		SettingsField(.whisperGapFill, keyPath: \.whisperGapFill, default: defaults.whisperGapFill,
		              decode: { container, key, value in (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? value }).eraseToAny()
	]
}
