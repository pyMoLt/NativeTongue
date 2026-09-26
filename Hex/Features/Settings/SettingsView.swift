import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// „Einstellungen“: hotkeys, microphone, sounds, insertion, memory, history.
/// Mode, profile, language and models live on the „Diktat“/„Modelle“ pages.
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

			HotKeySectionView(store: store)

			if microphonePermission == .granted {
				MicrophoneSelectionSectionView(store: store)
			}

			Section {
				Toggle(
					"Keep the transcript on the clipboard after inserting",
					isOn: Binding(
						get: { store.hexSettings.copyToClipboard },
						set: { value in store.$hexSettings.withLock { $0.copyToClipboard = value } }
					)
				)
				Text("Off (default): after every dictation your previous clipboard is fully restored – including images and files.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Insert")
			}

			Section {
				Picker(
					"Unload idle model",
					selection: Binding(
						get: { store.hexSettings.idleUnloadMinutes },
						set: { store.send(.setIdleUnloadMinutes($0)) }
					)
				) {
					Text("Never").tag(0)
					Text("after 2 minutes").tag(2)
					Text("after 5 minutes").tag(5)
					Text("after 10 minutes").tag(10)
					Text("after 30 minutes").tag(30)
				}
				Text("Saves memory. The model preloads the next time you press the dictation key.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Memory")
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
