import Foundation

/// What the AI post-processing step may do (plan 2.5, section 3.2).
public enum PolishMode: String, Codable, CaseIterable, Equatable, Sendable {
	/// Minimal edits: word errors, punctuation, capitalisation, paragraphs, spelled letters.
	case clean
	/// Turns a spoken train of thought into a clear task.
	case rewrite

	public var displayName: String {
		switch self {
		case .clean: "Clean up"
		case .rewrite: "Rewrite as task"
		}
	}
}

/// How strictly the safety check compares the AI result with the original.
public enum GuardStrictness: String, Codable, CaseIterable, Equatable, Sendable {
	/// Length, numbers/units, vocabulary terms, negations and code must match.
	case strict
	/// Numbers/units, vocabulary terms, names, negations and code must still appear.
	case keyFacts
	/// Only a large change in length is flagged.
	case lengthOnly

	public var displayName: String {
		switch self {
		case .strict: "Strict"
		case .keyFacts: "Key facts"
		case .lengthOnly: "Length only"
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
	public var autoMode: PolishMode = .clean
	public var autoModel = ""
	public var minimumWords = 4
	public var timeoutSeconds = 15

	public var boxButtonEnabled = true
	public var boxDefaultMode: PolishMode = .clean
	public var boxModel = ""
	public var boxShowsDiffAutomatically = false

	public var guardEnabled = true
	public var cleanStrictness: GuardStrictness = .strict
	public var rewriteStrictness: GuardStrictness = .keyFacts
	public var lengthTolerancePercent = 25

	/// nil = built-in prompt (see `PolishPrompt`).
	public var customCleanPrompt: String?
	public var customRewritePrompt: String?
	/// "What matters to me" — appended to both prompts.
	public var personalNote = ""
	public var cleanMaxOutputFactor = 1.5
	public var rewriteMaxOutputFactor = 1.2

	public var unloadPolicy: LLMUnloadPolicy = .afterIdle
	public var idleUnloadMinutes = 5
	public var preloadOnHotkey = true

	public var customModels: [CustomLLMModel] = []

	public init() {}

	public func strictness(for mode: PolishMode) -> GuardStrictness {
		mode == .clean ? cleanStrictness : rewriteStrictness
	}

	public func maxOutputFactor(for mode: PolishMode) -> Double {
		mode == .clean ? cleanMaxOutputFactor : rewriteMaxOutputFactor
	}

	public func customPrompt(for mode: PolishMode) -> String? {
		mode == .clean ? customCleanPrompt : customRewritePrompt
	}

	private enum CodingKeys: String, CodingKey {
		case enabled, autoEnabled, autoScope, autoMode, autoModel, minimumWords, timeoutSeconds
		case boxButtonEnabled, boxDefaultMode, boxModel, boxShowsDiffAutomatically
		case guardEnabled, cleanStrictness, rewriteStrictness, lengthTolerancePercent
		case customCleanPrompt, customRewritePrompt, personalNote, cleanMaxOutputFactor, rewriteMaxOutputFactor
		case unloadPolicy, idleUnloadMinutes, preloadOnHotkey, customModels
	}

	/// Every field falls back to its default, so new settings never break old files.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = PostProcessingSettings()
		enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
		autoEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEnabled) ?? d.autoEnabled
		autoScope = try c.decodeIfPresent(PolishAutoScope.self, forKey: .autoScope) ?? d.autoScope
		autoMode = try c.decodeIfPresent(PolishMode.self, forKey: .autoMode) ?? d.autoMode
		autoModel = try c.decodeIfPresent(String.self, forKey: .autoModel) ?? d.autoModel
		minimumWords = try c.decodeIfPresent(Int.self, forKey: .minimumWords) ?? d.minimumWords
		timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
		boxButtonEnabled = try c.decodeIfPresent(Bool.self, forKey: .boxButtonEnabled) ?? d.boxButtonEnabled
		boxDefaultMode = try c.decodeIfPresent(PolishMode.self, forKey: .boxDefaultMode) ?? d.boxDefaultMode
		boxModel = try c.decodeIfPresent(String.self, forKey: .boxModel) ?? d.boxModel
		boxShowsDiffAutomatically = try c.decodeIfPresent(Bool.self, forKey: .boxShowsDiffAutomatically) ?? d.boxShowsDiffAutomatically
		guardEnabled = try c.decodeIfPresent(Bool.self, forKey: .guardEnabled) ?? d.guardEnabled
		cleanStrictness = try c.decodeIfPresent(GuardStrictness.self, forKey: .cleanStrictness) ?? d.cleanStrictness
		rewriteStrictness = try c.decodeIfPresent(GuardStrictness.self, forKey: .rewriteStrictness) ?? d.rewriteStrictness
		lengthTolerancePercent = try c.decodeIfPresent(Int.self, forKey: .lengthTolerancePercent) ?? d.lengthTolerancePercent
		customCleanPrompt = try c.decodeIfPresent(String.self, forKey: .customCleanPrompt)
		customRewritePrompt = try c.decodeIfPresent(String.self, forKey: .customRewritePrompt)
		personalNote = try c.decodeIfPresent(String.self, forKey: .personalNote) ?? d.personalNote
		cleanMaxOutputFactor = try c.decodeIfPresent(Double.self, forKey: .cleanMaxOutputFactor) ?? d.cleanMaxOutputFactor
		rewriteMaxOutputFactor = try c.decodeIfPresent(Double.self, forKey: .rewriteMaxOutputFactor) ?? d.rewriteMaxOutputFactor
		unloadPolicy = try c.decodeIfPresent(LLMUnloadPolicy.self, forKey: .unloadPolicy) ?? d.unloadPolicy
		idleUnloadMinutes = try c.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes) ?? d.idleUnloadMinutes
		preloadOnHotkey = try c.decodeIfPresent(Bool.self, forKey: .preloadOnHotkey) ?? d.preloadOnHotkey
		customModels = try c.decodeIfPresent([CustomLLMModel].self, forKey: .customModels) ?? d.customModels
	}
}
