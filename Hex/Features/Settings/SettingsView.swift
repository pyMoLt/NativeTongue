import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus
	let inputMonitoringPermission: PermissionStatus
  
	var body: some View {
		Form {
			if microphonePermission != .granted
				|| accessibilityPermission != .granted
				|| inputMonitoringPermission != .granted {
				PermissionsSectionView(
					store: store,
					microphonePermission: microphonePermission,
					accessibilityPermission: accessibilityPermission,
					inputMonitoringPermission: inputMonitoringPermission
				)
			}

			ModelSectionView(store: store, shouldFlash: store.shouldFlashModelSection)
			DictationModeSectionView(store: store)
			// Only show language picker for WhisperKit models (not Parakeet)
			if ParakeetModel(rawValue: store.hexSettings.selectedModel) == nil {
				LanguageSectionView(store: store)
			}

			HotKeySectionView(store: store)
          
			if microphonePermission == .granted {
				MicrophoneSelectionSectionView(store: store)
			}

			SoundSectionView(store: store)
			GeneralSectionView(store: store)
			HistorySectionView(store: store)
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
		.enableInjection()
	}
}

private struct DictationModeSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Picker(
				"Profile",
				selection: Binding(
					get: { store.hexSettings.asrProfile },
					set: { store.send(.setASRProfile($0)) }
				)
			) {
				ForEach(ASRProfile.allCases, id: \.self) { profile in
					Text(profile.displayName).tag(profile)
				}
			}
			.pickerStyle(.segmented)

			Picker(
				"Dictation mode",
				selection: Binding(
					get: { store.hexSettings.dictationMode },
					set: { store.send(.setDictationMode($0)) }
				)
			) {
				Text("Normal").tag(DictationMode.normal)
				Text("Literal punctuation").tag(DictationMode.literal)
			}
			.pickerStyle(.menu)

			HStack {
				Text("Command pause")
				Slider(
					value: Binding(
						get: { store.hexSettings.spokenCommandPauseSeconds },
						set: { store.send(.setSpokenCommandPause($0)) }
					),
					in: 0.25...1.0,
					step: 0.05
				)
				Text("\(Int((store.hexSettings.spokenCommandPauseSeconds * 1_000).rounded())) ms")
					.monospacedDigit()
					.frame(width: 62, alignment: .trailing)
			}

			VStack(alignment: .leading, spacing: 5) {
				Text("Additional terminology for \(store.hexSettings.asrProfile.displayName)")
					.font(.callout)
				TextEditor(text: Binding(
					get: { store.hexSettings.activeVocabulary },
					set: { store.send(.setProfileVocabulary(store.hexSettings.asrProfile, $0)) }
				))
				.font(.system(.caption, design: .monospaced))
				.frame(minHeight: 58, maxHeight: 90)
				.overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
				Text("Separate terms with commas or new lines. At most 64 terms / 800 characters are sent as decoder context. This biases spelling; it is not a deterministic replacement dictionary. Parakeet v3 currently ignores context hints.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Text(store.hexSettings.dictationMode == .normal
				? "Normal mode preserves the model's punctuation. Line and paragraph phrases become commands only when word timings show the configured pause immediately before or after the phrase; otherwise they stay as words."
				: "Literal mode converts explicitly spoken punctuation and brackets. Line and paragraph commands still require the configured pause immediately before or after the phrase. Whisper may add automatic punctuation, so audio validation with your voice remains necessary.")
				.font(.caption)
				.foregroundStyle(.secondary)
		} header: {
			Text("Dictation")
		}
	}
}

// MARK: - Shared Styles

extension Text {
	/// Applies caption font with secondary color, commonly used for helper/description text in settings.
	func settingsCaption() -> some View {
		self.font(.caption).foregroundStyle(.secondary)
	}
}
