import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import Inject
import SwiftUI

private let historyLogger = HexLog.history

// MARK: - Date Extensions

extension Date {
	func relativeFormatted() -> String {
		let calendar = Calendar.current
		let now = Date()
		
		if calendar.isDateInToday(self) {
			return "Today"
		} else if calendar.isDateInYesterday(self) {
			return "Yesterday"
		} else if let daysAgo = calendar.dateComponents([.day], from: self, to: now).day, daysAgo < 7 {
			let formatter = DateFormatter()
			formatter.dateFormat = "EEEE" // Day of week
			return formatter.string(from: self)
		} else {
			let formatter = DateFormatter()
			formatter.dateStyle = .medium
			formatter.timeStyle = .none
			return formatter.string(from: self)
		}
	}
}

// MARK: - Models

extension SharedReaderKey
	where Self == FileStorageKey<TranscriptionHistory>.Default
{
	static var transcriptionHistory: Self {
		Self[
			.fileStorage(.transcriptionHistoryURL),
			default: .init()
		]
	}
}

// MARK: - Storage Migration

extension URL {
	static var transcriptionHistoryURL: URL {
		get {
			URL.hexMigratedFileURL(named: "transcription_history.json")
		}
	}
}

class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
	private var player: AVAudioPlayer?
	private let (playbackFinishedStream, playbackFinishedContinuation) = AsyncStream<Void>.makeStream()

	func play(url: URL) throws {
		let player = try AVAudioPlayer(contentsOf: url)
		player.delegate = self
		self.player = player
		player.play()
	}

	func stop() {
		player?.stop()
		player = nil
		finishPlayback()
	}

	func waitForPlaybackToFinish() async {
		for await _ in playbackFinishedStream {}
	}

	// AVAudioPlayerDelegate method
	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		guard self.player === player else { return }
		self.player = nil
		finishPlayback()
	}

	private func finishPlayback() {
		playbackFinishedContinuation.finish()
	}
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		var playingTranscriptID: UUID?
		var playbackID: UUID?
		var audioPlayerController: AudioPlayerController?

		mutating func stopAudioPlayback() {
			audioPlayerController?.stop()
			audioPlayerController = nil
			playingTranscriptID = nil
			playbackID = nil
		}
	}

	enum Action {
		case playTranscript(UUID)
		case stopPlayback
		case copyToClipboard(String)
		case deleteTranscript(UUID)
		case deleteAllTranscripts
		case confirmDeleteAll
		case playbackFinished(UUID)
		case navigateToSettings
	}

	@Dependency(\.pasteboard) var pasteboard
	@Dependency(\.transcriptPersistence) var transcriptPersistence

	private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
		.run { [transcriptPersistence] _ in
			for transcript in transcripts {
				try? await transcriptPersistence.deleteAudio(transcript)
			}
		}
	}

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .playTranscript(id):
				if state.playingTranscriptID == id {
					// Stop playback if tapping the same transcript
					state.stopAudioPlayback()
					return .none
				}

				// Stop any existing playback
				state.stopAudioPlayback()

				// Find the transcript and play its audio
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}

				do {
					let controller = AudioPlayerController()
					try controller.play(url: transcript.audioPath)
					let playbackID = UUID()

					state.audioPlayerController = controller
					state.playingTranscriptID = id
					state.playbackID = playbackID

					return .run { send in
						await controller.waitForPlaybackToFinish()
						await send(.playbackFinished(playbackID))
					}
				} catch {
					historyLogger.error("Failed to play audio: \(error.localizedDescription)")
					return .none
				}

			case .stopPlayback:
				state.stopAudioPlayback()
				return .none

			case let .playbackFinished(playbackID):
				guard state.playbackID == playbackID else { return .none }
				state.stopAudioPlayback()
				return .none

			case let .copyToClipboard(text):
				return .run { [pasteboard] _ in
					await pasteboard.copy(text)
				}

			case let .deleteTranscript(id):
				guard let index = state.transcriptionHistory.history.firstIndex(where: { $0.id == id }) else {
					return .none
				}

				let transcript = state.transcriptionHistory.history[index]

				if state.playingTranscriptID == id {
					state.stopAudioPlayback()
				}

				_ = state.$transcriptionHistory.withLock { history in
					history.history.remove(at: index)
				}

				return deleteAudioEffect(for: [transcript])

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				let transcripts = state.transcriptionHistory.history
				state.stopAudioPlayback()

				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}

				return deleteAudioEffect(for: transcripts)
				
			case .navigateToSettings:
				// This will be handled by the parent reducer
				return .none
			}
		}
	}
}

struct TranscriptView: View {
	let transcript: Transcript
	let isPlaying: Bool
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onDelete: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(transcript.text)
				.flowFont(.body)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.textSelection(.enabled)
				.padding(.horizontal, 16)
				.padding(.top, 14)
				.padding(.bottom, 6)

			HStack {
				HStack(spacing: 6) {
					// App icon and name
					if let bundleID = transcript.sourceAppBundleID,
					   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
						Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
							.resizable()
							.frame(width: 14, height: 14)
						if let appName = transcript.sourceAppName {
							Text(appName)
						}
						Text("•")
					}
					
					Image(systemName: "clock")
					Text(transcript.timestamp.relativeFormatted())
					Text("•")
					Text(transcript.timestamp.formatted(date: .omitted, time: .shortened))
					Text("•")
					Text(String(format: "%.1fs", transcript.duration))
				}
				.flowFont(.caption)
				.foregroundStyle(.secondary)

				Spacer()

				HStack(spacing: 10) {
					Button {
						onCopy()
						showCopyAnimation()
					} label: {
						HStack(spacing: 4) {
							Image(systemName: showCopied ? "checkmark" : "doc.on.doc.fill")
							if showCopied {
								Text("Copied").flowFont(.caption)
							}
						}
					}
					.buttonStyle(.plain)
					.foregroundStyle(showCopied ? .green : .secondary)
					.help("Copy to clipboard")

					Button(action: onPlay) {
						Image(systemName: isPlaying ? "stop.fill" : "play.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
					.help(isPlaying ? "Stop playback" : "Play audio")

					Button(action: onDelete) {
						Image(systemName: "trash.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.help("Delete transcript")
				}
				.flowFont(.subheadline)
			}
			.frame(height: 20)
			.padding(.horizontal, 16)
			.padding(.bottom, 12)
		}
		.flowPanel()
		.onDisappear {
			// Clean up any running task when view disappears
			copyTask?.cancel()
		}
	}

	@State private var showCopied = false
	@State private var copyTask: Task<Void, Error>?

	private func showCopyAnimation() {
		copyTask?.cancel()

		copyTask = Task {
			withAnimation {
				showCopied = true
			}

			try await Task.sleep(for: .seconds(1.5))

			withAnimation {
				showCopied = false
			}
		}
	}
}

#Preview {
	TranscriptView(
		transcript: Transcript(timestamp: Date(), text: "Hello, world!", audioPath: URL(fileURLWithPath: "/tmp/sample-recording.m4a"), duration: 1.0),
		isPlaying: false,
		onPlay: {},
		onCopy: {},
		onDelete: {}
	)
}

struct HistoryView: View {
	@ObserveInjection var inject
	let store: StoreOf<HistoryFeature>
	@Bindable var settingsStore: StoreOf<SettingsFeature>
	@State private var showingDeleteConfirmation = false
	@Shared(.hexSettings) var hexSettings: HexSettings

	var body: some View {
		FlowPage("History", subtitle: "Your past dictations – only if you turn saving on. Everything stays on this Mac.", symbol: "clock") {
			FlowGroup("Saving", footer: hexSettings.saveTranscriptionHistory ? nil : "When off, transcriptions are not saved and audio files are deleted right after transcription.") {
				Toggle(isOn: Binding(
					get: { hexSettings.saveTranscriptionHistory },
					set: { settingsStore.send(.toggleSaveTranscriptionHistory($0)) }
				)) {
					FlowLabel("Save transcription history", caption: "Keeps transcripts and their recordings for later access.")
				}
				if hexSettings.saveTranscriptionHistory {
					Picker("Maximum entries", selection: Binding(
						get: { hexSettings.maxHistoryEntries ?? 0 },
						set: { settingsStore.send(.setMaxHistoryEntries($0 == 0 ? nil : $0)) }
					)) {
						Text("Unlimited").tag(0)
						Text("50").tag(50)
						Text("100").tag(100)
						Text("200").tag(200)
						Text("500").tag(500)
						Text("1000").tag(1000)
					}
					.flowRow("Maximum entries", caption: hexSettings.maxHistoryEntries != nil ? "The oldest entries are deleted when the limit is reached." : nil)
				}
			}

			if hexSettings.saveTranscriptionHistory {
				FlowGroup("Transcripts") {
					if store.transcriptionHistory.history.isEmpty {
						FlowBlock {
							FlowEmptyState(symbol: "text.bubble", title: "No transcripts yet", message: "Your dictations will appear here.")
						}
					} else {
						LazyVStack(spacing: FlowMetrics.pillSpacing) {
							ForEach(store.transcriptionHistory.history) { transcript in
								TranscriptView(
									transcript: transcript,
									isPlaying: store.playingTranscriptID == transcript.id,
									onPlay: { store.send(.playTranscript(transcript.id)) },
									onCopy: { store.send(.copyToClipboard(transcript.text)) },
									onDelete: { store.send(.deleteTranscript(transcript.id)) }
								)
							}
						}
						HStack {
							Spacer()
							Button(role: .destructive) { showingDeleteConfirmation = true } label: {
								Label("Delete all", systemImage: "trash")
							}
							.buttonStyle(.flowDestructive)
						}
					}
				}
			}
		}
		.alert("Delete All Transcripts", isPresented: $showingDeleteConfirmation) {
			Button("Delete All", role: .destructive) {
				store.send(.confirmDeleteAll)
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Are you sure you want to delete all transcripts? This action cannot be undone.")
		}
		.enableInjection()
	}
}
