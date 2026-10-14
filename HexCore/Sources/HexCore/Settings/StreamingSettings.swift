import Foundation

/// How the dictation key controls a streaming session.
public enum StreamingHotkeyBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	/// Press once to start, press again to stop.
	case toggle
	/// Stream while the key is held.
	case hold

	public var displayName: String {
		switch self {
		case .toggle: "Press to start, press again to stop"
		case .hold: "Hold to stream"
		}
	}
}

/// Which spoken commands are applied while streaming.
public enum StreamingVoiceCommands: String, Codable, CaseIterable, Equatable, Sendable {
	case off
	case lineBreaksOnly
	/// Spoken punctuation only (Streaming Literal, basic scope).
	case punctuationOnly
	case all

	public var displayName: String {
		switch self {
		case .off: "Off"
		case .lineBreaksOnly: "Only “new line” / “new paragraph”"
		case .punctuationOnly: "Punctuation words"
		case .all: "All commands"
		}
	}
}

/// Where punctuation comes from while streaming.
public enum StreamingPunctuationMode: String, Codable, CaseIterable, Equatable, Sendable {
	/// The model sets punctuation and capitals.
	case automatic
	/// Only spoken punctuation ("Komma", "Punkt", "Klammer auf") — like Literal.
	case literal
	/// The model's punctuation plus spoken punctuation commands.
	case combined

	public var displayName: String {
		switch self {
		case .automatic: "Streaming Normal"
		case .literal: "Streaming Literal"
		case .combined: "Streaming Normal + spoken commands"
		}
	}
}

/// Which spoken commands Streaming Literal understands.
public enum StreamingLiteralScope: String, Codable, CaseIterable, Equatable, Sendable {
	/// Punkt, Komma, Fragezeichen, Ausrufezeichen.
	case basic
	/// Everything: colon, brackets, quotes, hyphen, new line/paragraph, format words.
	case extended

	public var displayName: String {
		switch self {
		case .basic: "Basic: Punkt, Komma, ?, !"
		case .extended: "Extended: also : ; ( ) „ “ - / new line, new paragraph …"
		}
	}

	public static let basicMarks: Set<PunctuationMark> = [.period, .comma, .question, .exclamation]
}

/// How streamed text reaches the target app.
public enum StreamingInsertionMethod: String, Codable, CaseIterable, Equatable, Sendable {
	/// Synthesized Unicode key events (never touches the clipboard).
	case keyboard
	/// Accessibility "selected text" replacement at the cursor.
	case accessibility

	public var displayName: String {
		switch self {
		case .keyboard: "Keyboard input"
		case .accessibility: "Accessibility"
		}
	}
}

/// What happens when the user switches to another app while streaming.
public enum StreamingAppSwitchBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case pause
	case continueInNewApp
	case stop

	public var displayName: String {
		switch self {
		case .pause: "Pause until you come back"
		case .continueInNewApp: "Continue in the new app"
		case .stop: "Stop streaming"
		}
	}
}

/// Settings of Streaming mode (plan 2.5, section 4.1).
public struct StreamingSettings: Codable, Equatable, Sendable {
	public var hotkeyBehavior: StreamingHotkeyBehavior = .toggle
	/// Stop after this many seconds without speech (0 = never).
	public var autoStopSilenceSeconds = 60
	public var literalStreamingInBox = false
	/// Empty = recommended streaming model.
	public var model = ""
	/// Nemotron chunk size in ms (560 / 1120 / 2240 / 4480): latency vs. accuracy.
	public var nemotronChunkMs = 1120
	/// Emulated streaming: pause that ends a block.
	public var emulatedPauseMs = 600
	/// Emulated streaming: longest block without a pause.
	public var emulatedMaxBlockSeconds = 12
	public var punctuationMode: StreamingPunctuationMode = .automatic
	public var literalScope: StreamingLiteralScope = .extended
	/// Legacy switch (V2.5 first build); `punctuationMode` decides now.
	public var keepModelPunctuation = true
	public var adaptSpacingAndCase = true
	public var lexiconCorrection = true
	public var formatNumbers = true
	/// Backticks and file names for code ("Punkt swift" → `.swift`).
	public var codeFormatting = false
	public var voiceCommands: StreamingVoiceCommands = .off
	public var insertionMethod: StreamingInsertionMethod = .keyboard
	public var appSwitchBehavior: StreamingAppSwitchBehavior = .pause
	public var showsPendingText = true
	/// „streich das“, „lösch das letzte Wort“, „ersetze X durch Y“ … as a separate
	/// utterance edit the text NativeTongue typed in this session (plan B1).
	public var correctionCommands = true

	/// Catalog name of the recommended streaming model (native streaming, German).
	public static let recommendedModel = "nemotron-3.5-streaming-multilingual-coreml"

	public init() {}

	private enum CodingKeys: String, CodingKey {
		case hotkeyBehavior, autoStopSilenceSeconds, literalStreamingInBox, model, nemotronChunkMs
		case emulatedPauseMs, emulatedMaxBlockSeconds, keepModelPunctuation, adaptSpacingAndCase, punctuationMode, codeFormatting, literalScope
		case lexiconCorrection, formatNumbers, voiceCommands, insertionMethod, appSwitchBehavior, showsPendingText
		case correctionCommands
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = StreamingSettings()
		hotkeyBehavior = try c.decodeIfPresent(StreamingHotkeyBehavior.self, forKey: .hotkeyBehavior) ?? d.hotkeyBehavior
		autoStopSilenceSeconds = try c.decodeIfPresent(Int.self, forKey: .autoStopSilenceSeconds) ?? d.autoStopSilenceSeconds
		literalStreamingInBox = try c.decodeIfPresent(Bool.self, forKey: .literalStreamingInBox) ?? d.literalStreamingInBox
		model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
		nemotronChunkMs = try c.decodeIfPresent(Int.self, forKey: .nemotronChunkMs) ?? d.nemotronChunkMs
		emulatedPauseMs = try c.decodeIfPresent(Int.self, forKey: .emulatedPauseMs) ?? d.emulatedPauseMs
		emulatedMaxBlockSeconds = try c.decodeIfPresent(Int.self, forKey: .emulatedMaxBlockSeconds) ?? d.emulatedMaxBlockSeconds
		keepModelPunctuation = try c.decodeIfPresent(Bool.self, forKey: .keepModelPunctuation) ?? d.keepModelPunctuation
		punctuationMode = try c.decodeIfPresent(StreamingPunctuationMode.self, forKey: .punctuationMode)
			?? (keepModelPunctuation ? .automatic : .literal)
		codeFormatting = try c.decodeIfPresent(Bool.self, forKey: .codeFormatting) ?? d.codeFormatting
		literalScope = try c.decodeIfPresent(StreamingLiteralScope.self, forKey: .literalScope) ?? d.literalScope
		adaptSpacingAndCase = try c.decodeIfPresent(Bool.self, forKey: .adaptSpacingAndCase) ?? d.adaptSpacingAndCase
		lexiconCorrection = try c.decodeIfPresent(Bool.self, forKey: .lexiconCorrection) ?? d.lexiconCorrection
		formatNumbers = try c.decodeIfPresent(Bool.self, forKey: .formatNumbers) ?? d.formatNumbers
		voiceCommands = try c.decodeIfPresent(StreamingVoiceCommands.self, forKey: .voiceCommands) ?? d.voiceCommands
		insertionMethod = try c.decodeIfPresent(StreamingInsertionMethod.self, forKey: .insertionMethod) ?? d.insertionMethod
		appSwitchBehavior = try c.decodeIfPresent(StreamingAppSwitchBehavior.self, forKey: .appSwitchBehavior) ?? d.appSwitchBehavior
		showsPendingText = try c.decodeIfPresent(Bool.self, forKey: .showsPendingText) ?? d.showsPendingText
		correctionCommands = (try? c.decodeIfPresent(Bool.self, forKey: .correctionCommands)) ?? d.correctionCommands
	}
}
