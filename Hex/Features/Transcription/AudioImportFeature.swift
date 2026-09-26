import AppKit
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI
import UniformTypeIdentifiers
import WhisperKit

@Reducer
struct AudioImportFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.hexSettings) var hexSettings: HexSettings
    var selectedFileURL: URL?
    var isCheckingModel = false
    var modelAvailabilityIdentifier: String?
    var isSelectedModelInstalled = false
    var isTranscribing = false
    var activeRequestID: UUID?
    var resultText: String?
    var errorMessage: String?

    var canTranscribe: Bool {
      selectedFileURL != nil
        && !isTranscribing
        && !hexSettings.selectedModel.isEmpty
        && modelAvailabilityIdentifier == hexSettings.selectedModel
        && isSelectedModelInstalled
    }
  }

  enum Action {
    case fileSelected(URL)
    case fileSelectionFailed(String)
    case clearFile
    case checkModelAvailability
    case modelAvailabilityChecked(model: String, isInstalled: Bool)
    case transcribe(requestID: UUID)
    case transcriptionCompleted(id: UUID, text: String?, errorMessage: String?)
    case resultEdited(String)
    case copyResult
    case openModelSettings
    case clearError
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.pasteboard) var pasteboard

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .fileSelected(url):
        guard !state.isTranscribing else { return .none }
        state.selectedFileURL = url
        state.resultText = nil
        state.errorMessage = nil
        return .none

      case let .fileSelectionFailed(message):
        state.errorMessage = message
        return .none

      case .clearFile:
        guard !state.isTranscribing else { return .none }
        state.selectedFileURL = nil
        state.resultText = nil
        state.errorMessage = nil
        return .none

      case .checkModelAvailability:
        let model = state.hexSettings.selectedModel
        guard !model.isEmpty else {
          state.isCheckingModel = false
          state.modelAvailabilityIdentifier = model
          state.isSelectedModelInstalled = false
          return .none
        }

        state.isCheckingModel = true
        state.modelAvailabilityIdentifier = nil
        return .run { [transcription] send in
          let isInstalled = await transcription.isModelDownloaded(model)
          await send(.modelAvailabilityChecked(model: model, isInstalled: isInstalled))
        }

      case let .modelAvailabilityChecked(model, isInstalled):
        guard state.hexSettings.selectedModel == model else { return .none }
        state.isCheckingModel = false
        state.modelAvailabilityIdentifier = model
        state.isSelectedModelInstalled = isInstalled
        return .none

      case let .transcribe(requestID):
        guard let url = state.selectedFileURL else {
          state.errorMessage = "Choose an audio file first."
          return .none
        }
        let model = state.hexSettings.selectedModel
        guard !model.isEmpty else {
          state.errorMessage = "Choose a local model in Settings before transcribing."
          return .none
        }
        guard state.modelAvailabilityIdentifier == model, state.isSelectedModelInstalled else {
          state.errorMessage = "The selected model is not installed. Install it in Settings → Models first."
          return .none
        }

        state.isTranscribing = true
        state.activeRequestID = requestID
        state.resultText = nil
        state.errorMessage = nil

        let settings = state.hexSettings
        let options = DecodingOptions(
          language: settings.outputLanguage,
          detectLanguage: settings.outputLanguage == nil,
          wordTimestamps: true,
          chunkingStrategy: .vad
        )
		let requestOptions = ASRTranscriptionOptions(
			decoding: options,
			terminologyContext: settings.activeTerminologyPrompt
		)

        return .run { [transcription] send in
          let openedSecurityScope = url.startAccessingSecurityScopedResource()
          defer {
            if openedSecurityScope {
              url.stopAccessingSecurityScopedResource()
            }
          }

          do {
            let output = try await transcription.transcribe(url, model, requestOptions) { _ in }
            let processedText = Self.process(output, settings: settings)
            await send(.transcriptionCompleted(id: requestID, text: processedText, errorMessage: nil))
          } catch {
            await send(.transcriptionCompleted(id: requestID, text: nil, errorMessage: error.localizedDescription))
          }
        }

      case let .transcriptionCompleted(id, text, errorMessage):
        guard state.activeRequestID == id else { return .none }
        state.activeRequestID = nil
        state.isTranscribing = false
        state.resultText = text
        state.errorMessage = errorMessage
        return .none

      case let .resultEdited(text):
        state.resultText = text
        return .none

      case .copyResult:
        guard let text = state.resultText, !text.isEmpty else { return .none }
        return .run { [pasteboard] _ in
          await pasteboard.copy(text)
        }

      case .openModelSettings:
        return .none

      case .clearError:
        state.errorMessage = nil
        return .none
      }
    }
  }

  private static func process(_ output: TranscriptionOutput, settings: HexSettings) -> String {
    var text = SpokenCommandFormatter.apply(
      output.text,
      mode: settings.dictationMode,
      wordTimings: output.wordTimings,
	  minimumCommandPause: settings.spokenCommandPauseSeconds
    )
    if settings.wordRemovalsEnabled {
      text = WordRemovalApplier.apply(text, removals: settings.wordRemovals)
    }
    text = WordRemappingApplier.apply(text, remappings: settings.wordRemappings)
    return TranscriptFormattingApplier.apply(
      text,
      lowercase: settings.lowercaseTranscripts,
      removePunctuation: settings.removePunctuation
    )
  }
}

struct AudioImportView: View {
  @ObserveInjection var inject
  let store: StoreOf<AudioImportFeature>
  @State private var isFileImporterPresented = false
  @State private var saveErrorMessage: String?
  @State private var isDropTargeted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Transcribe an audio file")
          .font(.title2.weight(.semibold))
        Text("The selected local model processes the file on this Mac. Audio and transcript are not saved or inserted automatically.")
          .foregroundStyle(.secondary)
      }

      audioDropZone

      GroupBox("Selected local model") {
        VStack(alignment: .leading, spacing: 8) {
          if store.hexSettings.selectedModel.isEmpty {
            Label("No model selected", systemImage: "exclamationmark.circle")
              .foregroundStyle(.secondary)
            Button("Open Settings") { store.send(.openModelSettings) }
          } else {
            Text(store.hexSettings.selectedModel)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
            if store.isCheckingModel || store.modelAvailabilityIdentifier != store.hexSettings.selectedModel {
              ProgressView("Checking local installation…")
                .controlSize(.small)
            } else if store.isSelectedModelInstalled {
              Label("Installed locally", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else {
              Label("Not installed", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
              Button("Open model settings") { store.send(.openModelSettings) }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button("Transcribe locally", systemImage: "waveform.badge.mic") {
          store.send(.transcribe(requestID: UUID()))
        }
        .buttonStyle(.borderedProminent)
        .disabled(!store.canTranscribe)

        if store.isTranscribing {
          ProgressView("Transcribing locally…")
            .controlSize(.small)
        }
      }

      if let errorMessage = store.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      if store.resultText != nil {
        VStack(alignment: .leading, spacing: 10) {
          Text("Transcript")
            .font(.headline)
          TextEditor(text: Binding(
            get: { store.resultText ?? "" },
            set: { store.send(.resultEdited($0)) }
          ))
          .font(.body)
          .frame(minHeight: 240)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

          HStack {
            Button("Copy", systemImage: "doc.on.doc") {
              store.send(.copyResult)
            }
            .disabled(store.resultText?.isEmpty ?? true)

            Button("Save as Text…", systemImage: "square.and.arrow.down") {
              saveResult()
            }
            .disabled(store.resultText?.isEmpty ?? true)
          }
        }
      } else if store.selectedFileURL == nil {
        ContentUnavailableView("No audio selected", systemImage: "waveform", description: Text("Choose an audio file to transcribe it locally."))
          .frame(maxWidth: .infinity, minHeight: 180)
      }

      Spacer(minLength: 0)
    }
    .padding(24)
    .fileImporter(
      isPresented: $isFileImporterPresented,
      allowedContentTypes: [.audio],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case let .success(urls):
        guard let url = urls.first else {
          store.send(.fileSelectionFailed("No audio file was selected."))
          return
        }
        store.send(.fileSelected(url))
      case let .failure(error):
        guard (error as NSError).code != NSUserCancelledError else { return }
        store.send(.fileSelectionFailed(error.localizedDescription))
      }
    }
    .task(id: store.hexSettings.selectedModel) {
      store.send(.checkModelAvailability)
    }
    .alert("Couldn’t save transcript", isPresented: Binding(
      get: { saveErrorMessage != nil },
      set: { if !$0 { saveErrorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { saveErrorMessage = nil }
    } message: {
      Text(saveErrorMessage ?? "")
    }
    .enableInjection()
  }

  private var audioDropZone: some View {
    HStack(spacing: 12) {
      Image(systemName: store.selectedFileURL == nil ? "waveform.badge.plus" : "doc.waveform")
        .font(.title2)
        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

      VStack(alignment: .leading, spacing: 3) {
        if let fileURL = store.selectedFileURL {
          Text(fileURL.lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
          Text("Drop another audio file here to replace it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Drop an audio file here")
            .font(.body.weight(.medium))
          Text("or choose one with the file picker")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Button("Choose…") { isFileImporterPresented = true }
        .disabled(store.isTranscribing)
      if store.selectedFileURL != nil {
        Button("Clear") { store.send(.clearFile) }
          .disabled(store.isTranscribing)
      }
    }
    .padding(14)
    .background(
      isDropTargeted ? Color.accentColor.opacity(0.09) : Color(NSColor.controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
          style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4])
        )
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !store.isTranscribing, let url = urls.first(where: AudioImportFileValidator.isSupportedAudioFile) else {
        if !store.isTranscribing {
          store.send(.fileSelectionFailed("Drop a supported local audio file."))
        }
        return false
      }
      store.send(.fileSelected(url))
      return true
    } isTargeted: { isTargeted in
      isDropTargeted = isTargeted && !store.isTranscribing
    }
  }

  private func saveResult() {
    guard let text = store.resultText, !text.isEmpty else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "Transcript.txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      saveErrorMessage = error.localizedDescription
    }
  }
}

enum AudioImportFileValidator {
  static func isSupportedAudioFile(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .audio)
  }
}
