import Foundation

/// How strictly the safety check compares the AI result with the original.
public enum GuardStrictness: String, Codable, CaseIterable, Equatable, Sendable {
	/// Length, numbers/units, vocabulary terms, negations and code must match.
	case strict
	/// Numbers/units, vocabulary terms, names, negations and code must still appear.
	case keyFacts
	/// Only a large change in length is flagged.
	case lengthOnly
	/// No check (summaries, fact lists, own instructions).
	case off

	public var displayName: String {
		switch self {
		case .strict: "Strict"
		case .keyFacts: "Key facts"
		case .lengthOnly: "Length only"
		case .off: "Off"
		}
	}
}

/// When the language model leaves memory.
public enum LLMUnloadPolicy: String, Codable, CaseIterable, Equatable, Sendable {
	case afterEachTask
	case afterIdle
	case never

	public var displayName: String {
		switch self {
		case .afterEachTask: "After each task"
		case .afterIdle: "After idle time"
		case .never: "Keep loaded"
		}
	}
}

/// Which dictations the automatic step runs on.
public enum PolishAutoScope: String, Codable, CaseIterable, Equatable, Sendable {
	case normalOnly
	case normalAndLiteralWithoutBox

	public var displayName: String {
		switch self {
		case .normalOnly: "Normal mode"
		case .normalAndLiteralWithoutBox: "Normal and Literal (without dictation box)"
		}
	}
}

/// A model added by the user from a Hugging Face link.
public struct CustomLLMModel: Codable, Equatable, Identifiable, Sendable {
	public var repository: String
	public var revision: String
	public var modelType: String?
	public var license: String?
	public var downloadBytes: Int64

	public var id: String { "custom:\(repository)" }

	public init(repository: String, revision: String, modelType: String?, license: String?, downloadBytes: Int64) {
		self.repository = repository
		self.revision = revision
		self.modelType = modelType
		self.license = license
		self.downloadBytes = downloadBytes
	}
}

/// Settings of the optional local AI post-processing (all off by default).
public struct PostProcessingSettings: Codable, Equatable, Sendable {
	public var enabled = false

	public var autoEnabled = false
	public var autoScope: PolishAutoScope = .normalOnly
	/// AI style of the automatic step (see `AIStyleCatalog`).
	public var autoStyleID = AIStyleCatalog.cleanID
	public var autoModel = ""
	public var minimumWords = 4
	public var timeoutSeconds = 15

	public var boxButtonEnabled = true
	/// Style the ✨ button uses on click; the menu offers all styles.
	public var boxStyleID = AIStyleCatalog.cleanID
	public var boxModel = ""
	public var boxShowsDiffAutomatically = false

	/// Master switch of the safety check; each style sets its own strictness.
	public var guardEnabled = true

	/// Built-in styles the user edited (same id as the built-in).
	public var editedStyles: [AIStyle] = []
	/// Styles the user created.
	public var customStyles: [AIStyle] = []
	/// "What matters to me" — appended to every style.
	public var personalNote = ""
	/// Command Mode (C3): rewrite selected text by voice; off by default.
	public var commandModeEnabled = false
	/// Context from the text field (C4); off by default.
	public var context = ContextSettings()

	public var unloadPolicy: LLMUnloadPolicy = .afterIdle
	public var idleUnloadMinutes = 5
	public var preloadOnHotkey = true

	public var customModels: [CustomLLMModel] = []

	public init() {}

	// MARK: Styles

	/// Built-in styles (with the user's edits) followed by the user's own.
	public var allStyles: [AIStyle] {
		AIStyleCatalog.builtIns.map { builtIn in editedStyles.first { $0.id == builtIn.id } ?? builtIn } + customStyles
	}

	/// The style with this id; unknown ids fall back to "Clean up".
	public func style(id: String) -> AIStyle {
		allStyles.first { $0.id == id } ?? allStyles[0]
	}

	public var autoStyle: AIStyle { style(id: autoStyleID) }
	public var boxStyle: AIStyle { style(id: boxStyleID) }

	public func isEdited(_ id: String) -> Bool {
		editedStyles.contains { $0.id == id }
	}

	/// Stores a built-in edit or a user style.
	public mutating func save(_ style: AIStyle) {
		if style.isBuiltIn {
			editedStyles.removeAll { $0.id == style.id }
			if style != AIStyleCatalog.builtIn(id: style.id) { editedStyles.append(style) }
		} else if let index = customStyles.firstIndex(where: { $0.id == style.id }) {
			customStyles[index] = style
		} else {
			customStyles.append(style)
		}
	}

	public mutating func restoreDefault(_ id: String) {
		editedStyles.removeAll { $0.id == id }
	}

	/// Deletes a user style; selections that used it fall back to "Clean up".
	public mutating func deleteStyle(_ id: String) {
		guard AIStyleCatalog.builtIn(id: id) == nil else { return }
		customStyles.removeAll { $0.id == id }
		if autoStyleID == id { autoStyleID = AIStyleCatalog.cleanID }
		if boxStyleID == id { boxStyleID = AIStyleCatalog.cleanID }
	}

	private enum CodingKeys: String, CodingKey {
		case enabled, autoEnabled, autoScope, autoStyleID, autoModel, minimumWords, timeoutSeconds
		case boxButtonEnabled, boxStyleID, boxModel, boxShowsDiffAutomatically
		case guardEnabled, editedStyles, customStyles, personalNote, context, commandModeEnabled
		case unloadPolicy, idleUnloadMinutes, preloadOnHotkey, customModels
	}

	/// Settings written before 2.6 (fixed modes instead of styles).
	private enum LegacyKeys: String, CodingKey {
		case autoMode, boxDefaultMode, cleanStrictness, rewriteStrictness, lengthTolerancePercent
		case customCleanPrompt, customRewritePrompt, cleanMaxOutputFactor, rewriteMaxOutputFactor
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(enabled, forKey: .enabled)
		try c.encode(autoEnabled, forKey: .autoEnabled)
		try c.encode(autoScope, forKey: .autoScope)
		try c.encode(autoStyleID, forKey: .autoStyleID)
		try c.encode(autoModel, forKey: .autoModel)
		try c.encode(minimumWords, forKey: .minimumWords)
		try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
		try c.encode(boxButtonEnabled, forKey: .boxButtonEnabled)
		try c.encode(boxStyleID, forKey: .boxStyleID)
		try c.encode(boxModel, forKey: .boxModel)
		try c.encode(boxShowsDiffAutomatically, forKey: .boxShowsDiffAutomatically)
		try c.encode(guardEnabled, forKey: .guardEnabled)
		try c.encode(editedStyles, forKey: .editedStyles)
		try c.encode(customStyles, forKey: .customStyles)
		try c.encode(personalNote, forKey: .personalNote)
		try c.encode(context, forKey: .context)
		try c.encode(commandModeEnabled, forKey: .commandModeEnabled)
		try c.encode(unloadPolicy, forKey: .unloadPolicy)
		try c.encode(idleUnloadMinutes, forKey: .idleUnloadMinutes)
		try c.encode(preloadOnHotkey, forKey: .preloadOnHotkey)
		try c.encode(customModels, forKey: .customModels)
	}

	/// Every field falls back to its default, so new settings never break old
	/// files; settings from before 2.6 are moved onto the styles.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = PostProcessingSettings()
		func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
			(try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
		}
		enabled = value(.enabled, d.enabled)
		autoEnabled = value(.autoEnabled, d.autoEnabled)
		autoScope = value(.autoScope, d.autoScope)
		autoModel = value(.autoModel, d.autoModel)
		minimumWords = value(.minimumWords, d.minimumWords)
		timeoutSeconds = value(.timeoutSeconds, d.timeoutSeconds)
		boxButtonEnabled = value(.boxButtonEnabled, d.boxButtonEnabled)
		boxModel = value(.boxModel, d.boxModel)
		boxShowsDiffAutomatically = value(.boxShowsDiffAutomatically, d.boxShowsDiffAutomatically)
		guardEnabled = value(.guardEnabled, d.guardEnabled)
		editedStyles = value(.editedStyles, d.editedStyles)
		customStyles = value(.customStyles, d.customStyles)
		personalNote = value(.personalNote, d.personalNote)
		context = value(.context, d.context)
		commandModeEnabled = value(.commandModeEnabled, d.commandModeEnabled)
		unloadPolicy = value(.unloadPolicy, d.unloadPolicy)
		idleUnloadMinutes = value(.idleUnloadMinutes, d.idleUnloadMinutes)
		preloadOnHotkey = value(.preloadOnHotkey, d.preloadOnHotkey)
		customModels = value(.customModels, d.customModels)

		let legacy = try decoder.container(keyedBy: LegacyKeys.self)
		func legacyMode(_ key: LegacyKeys) -> String? {
			(try? legacy.decodeIfPresent(String.self, forKey: key)).flatMap { $0 == "rewrite" ? AIStyleCatalog.taskID : $0 == "clean" ? AIStyleCatalog.cleanID : nil }
		}
		autoStyleID = (try? c.decodeIfPresent(String.self, forKey: .autoStyleID)) ?? legacyMode(.autoMode) ?? d.autoStyleID
		boxStyleID = (try? c.decodeIfPresent(String.self, forKey: .boxStyleID)) ?? legacyMode(.boxDefaultMode) ?? d.boxStyleID

		// Pre-2.6 prompt, strictness and budget edits become edited built-in styles.
		if !c.contains(.editedStyles) {
			let tolerance = try? legacy.decodeIfPresent(Int.self, forKey: .lengthTolerancePercent)
			for (id, promptKey, strictKey, factorKey) in [
				(AIStyleCatalog.cleanID, LegacyKeys.customCleanPrompt, LegacyKeys.cleanStrictness, LegacyKeys.cleanMaxOutputFactor),
				(AIStyleCatalog.taskID, .customRewritePrompt, .rewriteStrictness, .rewriteMaxOutputFactor),
			] {
				guard var style = AIStyleCatalog.builtIn(id: id) else { continue }
				if let prompt = (try? legacy.decodeIfPresent(String.self, forKey: promptKey)) ?? nil,
				   !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					style.instruction = prompt
				}
				if let strictness = (try? legacy.decodeIfPresent(GuardStrictness.self, forKey: strictKey)) ?? nil { style.strictness = strictness }
				if let factor = (try? legacy.decodeIfPresent(Double.self, forKey: factorKey)) ?? nil { style.outputFactor = factor }
				if let tolerance = tolerance ?? nil { style.lengthTolerancePercent = tolerance }
				save(style)
			}
		}
	}
}
