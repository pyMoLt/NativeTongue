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
                MenuPanelView(store: HexApp.appStore) {
                    appDelegate.presentSettingsView()
                }
            }
		} label: {
			MenuBarIcon(store: HexApp.appStore)
		}
		.menuBarExtraStyle(.window)
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
