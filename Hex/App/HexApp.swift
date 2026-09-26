import ComposableArchitecture
import Inject
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	} withDependencies: {
		if isTesting {
			$0.defaultFileStorage = .inMemory
		}
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
  
    var body: some Scene {
        MenuBarExtra {
            if isTesting {
                EmptyView()
            } else {
                MenuBarCopyLastTranscriptButton()

                Button("Transcribe Audio File…") {
                    HexApp.appStore.send(.setActiveTab(.audioImport))
                    appDelegate.presentSettingsView()
                }

                Button("Settings…") {
                    appDelegate.presentSettingsView()
                }.keyboardShortcut(",")

				Divider()

				Button("Quit Local ASR") {
					NSApplication.shared.terminate(nil)
				}.keyboardShortcut("q")
			}
		} label: {
			Image(systemName: "waveform")
				.symbolRenderingMode(.monochrome)
				.accessibilityLabel("Local ASR")
		}
		.commands {
			CommandGroup(after: .appInfo) {
				Button("Settings…") {
					appDelegate.presentSettingsView()
				}.keyboardShortcut(",")
			}

			CommandGroup(replacing: .help) {}
		}
	}
}
