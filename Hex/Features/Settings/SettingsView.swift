import ComposableArchitecture
import HexCore
import SwiftUI

/// "General" (2.6): permissions, start-up and how text is inserted.
/// Recording, models, history and appearance have their own pages.
struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus
  let inputMonitoringPermission: PermissionStatus

  private var settings: HexSettings { store.hexSettings }

  var body: some View {
    FlowPage("General", subtitle: "Permissions, start-up and how text reaches your apps", symbol: "gearshape") {
      permissionsGroup
      startGroup
      insertGroup
    }
    .task { await store.send(.task).finish() }
  }

  // MARK: Permissions

  private var permissionsGroup: some View {
    FlowGroup("Permissions", footer: "NativeTongue needs the microphone to hear you, Accessibility to insert text and Input Monitoring to notice the dictation key.") {
      permissionRow("Microphone", symbol: "mic.fill", status: microphonePermission) {
        store.send(.requestMicrophone)
      }
      permissionRow("Accessibility", symbol: "accessibility", status: accessibilityPermission) {
        store.send(.requestAccessibility)
      }
      permissionRow("Input Monitoring", symbol: "keyboard", status: inputMonitoringPermission) {
        store.send(.requestInputMonitoring)
      }
    }
  }

  private func permissionRow(_ title: String, symbol: String, status: PermissionStatus, action: @escaping () -> Void) -> some View {
    FlowRow(title, systemImage: symbol) {
      switch status {
      case .granted:
        Badge(text: "Allowed", systemImage: "checkmark.circle.fill", style: .positive)
      case .denied, .notDetermined:
        Button("Allow…", action: action)
          .buttonStyle(.flowPrimary)
      }
    }
  }

  // MARK: Start

  private var startGroup: some View {
    FlowGroup("Start") {
      Toggle(isOn: Binding(
        get: { settings.openOnLogin },
        set: { store.send(.toggleOpenOnLogin($0)) }
      )) {
        FlowLabel("Open at login", caption: "Starts quietly in the menu bar.")
      }
      Toggle(isOn: Binding(
        get: { settings.showDockIcon },
        set: { store.send(.toggleShowDockIcon($0)) }
      )) {
        FlowLabel("Show in the Dock")
      }
    }
  }

  // MARK: Insert

  private var insertGroup: some View {
    FlowGroup("Inserting text") {
      Toggle(isOn: Binding(
        get: { settings.useClipboardPaste },
        set: { store.send(.setUseClipboardPaste($0)) }
      )) {
        FlowLabel("Insert via the clipboard", caption: "Fast and works everywhere; your clipboard is restored afterwards. Off: simulated typing, slower but never touches the clipboard.")
      }
      Toggle(isOn: Binding(
        get: { settings.copyToClipboard },
        set: { value in store.$hexSettings.withLock { $0.copyToClipboard = value } }
      )) {
        FlowLabel("Keep the transcript on the clipboard", caption: "Off (default): after every dictation your previous clipboard is fully restored – including images and files.")
      }
    }
  }
}
