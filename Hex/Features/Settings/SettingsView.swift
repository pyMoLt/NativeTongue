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
					"Transkript nach dem Einfügen in der Zwischenablage behalten",
					isOn: Binding(
						get: { store.hexSettings.copyToClipboard },
						set: { value in store.$hexSettings.withLock { $0.copyToClipboard = value } }
					)
				)
				Text("Aus (Standard): Nach jedem Diktat wird deine vorherige Zwischenablage vollständig wiederhergestellt – auch Bilder und Dateien.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Einfügen")
			}

			Section {
				Picker(
					"Modell nach Leerlauf entladen",
					selection: Binding(
						get: { store.hexSettings.idleUnloadMinutes },
						set: { store.send(.setIdleUnloadMinutes($0)) }
					)
				) {
					Text("Nie").tag(0)
					Text("nach 2 Minuten").tag(2)
					Text("nach 5 Minuten").tag(5)
					Text("nach 10 Minuten").tag(10)
					Text("nach 30 Minuten").tag(30)
				}
				Text("Spart Arbeitsspeicher. Beim nächsten Drücken der Diktat-Taste wird das Modell vorgeladen.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Arbeitsspeicher")
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
