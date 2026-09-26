import ComposableArchitecture
import HexCore
import SwiftUI

private let appLogger = HexLog.app
private let cacheLogger = HexLog.caches

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var dictationBoxController: DictationBoxPanelController?
	var settingsWindow: NSWindow?
	var statusItem: NSStatusItem!
	private var launchedAtLogin = false

	@Dependency(\.soundEffects) var soundEffect
	@Dependency(\.recording) var recording

	func applicationDidFinishLaunching(_: Notification) {
		if isTesting {
			return
		}

		DiagnosticsLogging.bootstrapIfNeeded()
		resolveLiveDependenciesEagerly()
		// Ensure Parakeet/FluidAudio caches live under Application Support, not ~/.cache
		configureLocalCaches()

		Task {
			await soundEffect.preloadSounds()
			let soundEffectsEnabled = HexApp.appStore.withState { $0.hexSettings.soundEffectsEnabled }
			await soundEffect.setEnabled(soundEffectsEnabled)
		}
		launchedAtLogin = wasLaunchedAtLogin()
		appLogger.info("Application did finish launching")
		appLogger.notice("launchedAtLogin = \(self.launchedAtLogin)")

		// Set activation policy first
		updateAppMode()

		// Add notification observer
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: .updateAppMode,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handlePresentSettingsWindow),
			name: .presentSettingsWindow,
			object: nil
		)

		// Start long-running app effects (global hotkeys, permissions, etc.)
		startLifecycleTasksIfNeeded()

		// Then present main views
		presentMainView()
		dictationBoxController = DictationBoxPanelController(store: HexApp.appStore)

		guard shouldOpenForegroundUIOnLaunch else {
			appLogger.notice("Suppressing foreground windows for login launch")
			return
		}

		presentSettingsView()
		NSApp.activate(ignoringOtherApps: true)
	}

	private var shouldOpenForegroundUIOnLaunch: Bool {
		// When Hex launches at login, stay quietly in the menu bar regardless of
		// the dock-icon preference. Users who enabled "Open on Login" expect a
		// background launch; the Settings window can be opened later from the
		// menu bar item or ⌘, when needed.
		!launchedAtLogin
	}

	private func wasLaunchedAtLogin() -> Bool {
		guard let event = NSAppleEventManager.shared().currentAppleEvent else {
			return false
		}

		return event.eventID == AEEventID(kAEOpenApplication)
			&& event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
	}

	/// Several live clients create `@Shared(.hexSettings)` in their initializer.
	/// If that first initialization happens on a background effect while another
	/// thread mutates the settings (`withLock`), swift-dependencies' cache lock and
	/// swift-sharing's reference lock are taken in opposite order → deadlock at
	/// launch (hang report 2026-09-26 18:37). Resolve them once, on the main
	/// thread, before any effect starts.
	private func resolveLiveDependenciesEagerly() {
		@Dependency(\.recording) var recording
		@Dependency(\.pasteboard) var pasteboard
		@Dependency(\.keyEventMonitor) var keyEventMonitor
		@Dependency(\.soundEffects) var soundEffects
		@Dependency(\.transcription) var transcription
		@Dependency(\.lexicon) var lexicon
		_ = (recording, pasteboard, keyEventMonitor, soundEffects, transcription, lexicon)
	}

	private func startLifecycleTasksIfNeeded() {
		Task { @MainActor in
			await HexApp.appStore.send(.task).finish()
		}
	}

	/// Sets XDG_CACHE_HOME so FluidAudio stores models under our app's
	/// Application Support folder, keeping everything in one place.
    private func configureLocalCaches() {
        do {
            let cache = try URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            setenv("XDG_CACHE_HOME", cache.path, 1)
            cacheLogger.info("XDG_CACHE_HOME set to \(cache.path)")
        } catch {
            cacheLogger.error("Failed to configure local caches: \(error.localizedDescription)")
        }
    }

	func presentMainView() {
		guard invisibleWindow == nil else {
			return
		}
		let transcriptionStore = HexApp.appStore.scope(state: \.transcription, action: \.transcription)
		let transcriptionView = TranscriptionView(store: transcriptionStore).padding().padding(.top).padding(.top)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		invisibleWindow = InvisibleWindow.fromView(transcriptionView)
		invisibleWindow?.orderFrontRegardless()
	}

	func presentSettingsView() {
		if let settingsWindow = settingsWindow {
			settingsWindow.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let settingsView = AppView(store: HexApp.appStore)
		let settingsWindow = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		settingsWindow.titleVisibility = .visible
		settingsWindow.contentView = NSHostingView(rootView: settingsView)
		settingsWindow.isReleasedWhenClosed = false
		settingsWindow.minSize = .init(width: 620, height: 560)
		settingsWindow.setFrameAutosaveName("Settings")
		settingsWindow.center()
		settingsWindow.toolbarStyle = NSWindow.ToolbarStyle.unified
		settingsWindow.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		self.settingsWindow = settingsWindow
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
		}
	}

	@objc private func handlePresentSettingsWindow() {
		presentSettingsView()
	}

	@MainActor
	private func updateAppMode() {
		let showDockIcon = HexApp.appStore.withState { $0.hexSettings.showDockIcon }
		appLogger.debug("showDockIcon = \(showDockIcon)")
		if showDockIcon {
			NSApp.setActivationPolicy(.regular)
		} else {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		presentSettingsView()
		return true
	}

	func applicationWillTerminate(_: Notification) {
		// Wait for audio teardown before the process exits: a fire-and-forget Task here
		// raced process exit, crashing inside AVAudioEngine teardown while tap callbacks
		// were still in flight (#245). Pump the main run loop while waiting instead of
		// blocking outright - cleanup() hops to the main actor/main queue (media-key
		// resume, Core Audio listener removal), which a blocked main thread would deadlock.
		let recording = recording
		let semaphore = DispatchSemaphore(value: 0)
		Task.detached {
			await recording.cleanup()
			semaphore.signal()
		}
		let deadline = Date().addingTimeInterval(3)
		while semaphore.wait(timeout: .now()) == .timedOut {
			guard Date() < deadline else {
				appLogger.error("Recording cleanup timed out during app termination")
				return
			}
			RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
		}
	}
}
