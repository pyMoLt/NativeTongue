import ComposableArchitecture
import HexCore
import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
  @Bindable var store: StoreOf<FileTranscriptionFeature>
  @State private var isDropTargeted = false
  @State private var customPromptJobID: FileTranscriptionFeature.Job.ID?
  @State private var customPrompt = ""

  var body: some View {
    VStack(alignment: .leading, spacing: FlowMetrics.groupSpacing) {
      PageHeader(title: "Files", subtitle: "Transcribe recordings and videos on this Mac", symbol: "waveform.badge.plus")
      HStack(alignment: .top, spacing: 12) {
        queue
          .frame(width: 270)
        editor
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .flowPanel()
      }
      .frame(maxHeight: .infinity)
    }
    .padding(.horizontal, FlowMetrics.pagePadding)
    .padding(.top, 30)
    .padding(.bottom, FlowMetrics.pagePadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task { store.send(.task) }
    .fileImporter(
      isPresented: $store.isImporterPresented,
      allowedContentTypes: [.audio, .movie],
      allowsMultipleSelection: true
    ) { result in
      if case let .success(urls) = result { store.send(.addFiles(urls)) }
    }
    .sheet(isPresented: Binding(get: { customPromptJobID != nil }, set: { if !$0 { customPromptJobID = nil } })) {
      customPromptSheet
        .flowThemed(store.hexSettings.appearance)
    }
    .alert("Files", isPresented: Binding(
      get: { store.errorMessage != nil },
      set: { if !$0 { store.send(.binding(.set(\.errorMessage, nil))) } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(store.errorMessage ?? "")
    }
  }

  // MARK: Queue

  private var queue: some View {
    VStack(alignment: .leading, spacing: FlowMetrics.pillSpacing) {
      dropZone
      options
      List(selection: Binding(get: { store.selectedJobID }, set: { store.send(.selectJob($0)) })) {
        ForEach(store.jobs) { job in
          JobRow(job: job)
            .tag(job.id)
            .contextMenu {
              if job.status.isActive || job.status == .queued {
                Button("Cancel") { store.send(.cancelJob(job.id)) }
              } else {
                Button("Transcribe again") { store.send(.retryJob(job.id)) }
                Button("Remove", role: .destructive) { store.send(.removeJob(job.id)) }
              }
            }
        }
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
      .overlay {
        if store.jobs.isEmpty {
          Text("No files yet").foregroundStyle(.tertiary)
        }
      }
      .padding(6)
      .frame(maxHeight: .infinity)
      .flowPanel()
    }
  }

  private var dropZone: some View {
    Button {
      store.send(.binding(.set(\.isImporterPresented, true)))
    } label: {
      VStack(spacing: 6) {
        Image(systemName: "square.and.arrow.down.on.square").flowFont(.title2)
        Text("Drop audio or video files here").flowFont(.callout, weight: .medium)
        Text("or click to choose · m4a, mp3, wav, aiff, mp4, mov").flowFont(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 18)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .flowSurface(RoundedRectangle(cornerRadius: FlowMetrics.panelRadius, style: .continuous), highlighted: isDropTargeted)
    .overlay(
      RoundedRectangle(cornerRadius: FlowMetrics.panelRadius - 4, style: .continuous)
        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
        .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.35)))
        .padding(5)
    )
    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
      Task {
        var urls: [URL] = []
        for provider in providers {
          if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
            urls.append(url)
          } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil) {
            urls.append(url)
          }
        }
        await MainActor.run { _ = store.send(.addFiles(urls)) }
      }
      return true
    }
  }

  private var options: some View {
    VStack(alignment: .leading, spacing: FlowMetrics.pillSpacing) {
      FlowSegmented(selection: $store.modeForFiles, options: [FlowOption(DictationMode.normal, "Normal"), FlowOption(DictationMode.literal, "Literal")], compact: true)
        .flowRow("Mode")
      FlowRow("Separate speakers") {
        if store.isDiarizationInstalled {
          Toggle("", isOn: $store.diarizeByDefault)
            .toggleStyle(.switch)
            .controlSize(.small)
        } else if store.isInstallingDiarization {
          ProgressView(value: store.diarizationProgress).frame(width: 70)
        } else {
          Button("Install…") { store.send(.installDiarization) }
            .buttonStyle(.flowCompact)
            .help("Downloads the speaker separation models once. Nothing else is downloaded.")
        }
      }
      FlowNote("Applies to files added next · \((try? LocalASRModelCatalog.descriptor(named: store.hexSettings.selectedModel))?.displayName.components(separatedBy: " · ").first ?? "no model")")
    }
  }

  // MARK: Editor

  @ViewBuilder
  private var editor: some View {
    if let job = store.selectedJob {
      VStack(spacing: 0) {
        editorHeader(job)
        if let ai = job.ai {
          aiPanel(job, ai)
        }
        switch job.status {
        case .done where job.segments.isEmpty:
          placeholder("No speech found", symbol: "waveform.slash")
        case .done:
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
              ForEach(job.segments) { segment in
                SegmentRow(
                  segment: segment,
                  speakerName: TranscriptExporter.speakerName(segment.speaker, names: job.speakerNames),
                  isPlaying: store.playingSegmentID == segment.id,
                  onPlay: { store.send(.play(job.id, segment: segment.id)) },
                  onEdit: { store.send(.editSegment(job.id, segment: segment.id, text: $0)) }
                )
              }
            }
            .padding(20)
          }
        case let .failed(message):
          placeholder(message, symbol: "exclamationmark.triangle")
        case .cancelled:
          placeholder("Cancelled", symbol: "xmark.circle")
        case .queued:
          placeholder("Waiting in queue", symbol: "clock")
        case .loading:
          progressView("Reading audio …", nil)
        case let .transcribing(fraction):
          progressView("Transcribing …", fraction)
        case .diarizing:
          progressView("Separating speakers …", nil)
        }
      }
    } else {
      placeholder("Choose or drop a file", symbol: "waveform.badge.plus")
    }
  }

  private func editorHeader(_ job: FileTranscriptionFeature.Job) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(job.name).flowFont(.headline, design: .rounded).lineLimit(1)
        Text([job.duration.map { TranscriptExporter.clock($0) }, job.mode == .literal ? "Literal" : "Normal",
              job.diarize ? "speakers separated" : nil].compactMap { $0 }.joined(separator: " · "))
          .flowFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if !job.speakers.isEmpty {
        Menu {
          ForEach(job.speakers, id: \.self) { speaker in
            Button("Rename \(TranscriptExporter.speakerName(speaker, names: job.speakerNames) ?? "")…") {
              renameSpeaker(job: job, speaker: speaker)
            }
          }
        } label: {
          Label("Speakers", systemImage: "person.2")
        }
        .fixedSize()
      }
      Menu {
        ForEach(store.hexSettings.postProcessing.allStyles) { style in
          Button {
            store.send(.aiRun(job.id, styleID: style.id, instruction: ""))
          } label: {
            Label(style.name, systemImage: style.symbol)
          }
        }
        Divider()
        Button {
          customPromptJobID = job.id
        } label: {
          Label("Own instruction…", systemImage: "pencil.and.list.clipboard")
        }
      } label: {
        Label("AI", systemImage: "sparkles")
      }
      .fixedSize()
      .disabled(job.segments.isEmpty || job.ai?.isRunning == true)
      .help("Post-process the transcript with the local AI model")
      Button {
        store.send(.copyAll(job.id))
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .disabled(job.segments.isEmpty)
      Menu {
        ForEach(TranscriptExporter.Format.allCases, id: \.self) { format in
          Button(Self.formatTitle(format)) { store.send(.export(job.id, format)) }
        }
      } label: {
        Label("Export", systemImage: "square.and.arrow.up")
      }
      .fixedSize()
      .disabled(job.segments.isEmpty)
    }
    .buttonStyle(.flowCompact)
    .menuStyle(.button)
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .padding(.bottom, 6)
  }

  private func aiPanel(_ job: FileTranscriptionFeature.Job, _ ai: FileTranscriptionFeature.AIResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label(ai.styleName, systemImage: ai.styleSymbol)
          .flowFont(.subheadline, weight: .semibold, design: .rounded)
          .foregroundStyle(.tint)
        if ai.isRunning { ProgressView().controlSize(.small) }
        Spacer()
        if ai.isRunning {
          Button("Stop") { store.send(.aiCancel(job.id)) }
            .buttonStyle(.flowCompact)
        } else {
          Button {
            store.send(.aiCopy(job.id))
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(.flowCompact)
          .disabled(ai.text.isEmpty)
          Button {
            store.send(.aiDismiss(job.id))
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.flowQuiet)
          .help("Close the AI result")
          .accessibilityLabel("Close the AI result")
        }
      }
      ScrollView {
        Text(ai.text.isEmpty ? "Working on it …" : ai.text)
          .flowFont(.callout)
          .foregroundStyle(ai.text.isEmpty ? .secondary : .primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 220)
      if let note = ai.note {
        Text(note).flowFont(.caption).foregroundStyle(.orange)
      }
      Text("The transcript and its timings stay unchanged; export uses the transcript.")
        .flowFont(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .flowSurface(RoundedRectangle(cornerRadius: 18, style: .continuous), highlighted: true)
    .padding(.horizontal, 14)
    .padding(.bottom, 6)
  }

  private var customPromptSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      PageHeader(title: "Own instruction", subtitle: "Tell the local AI what to do with this transcript", symbol: "pencil.and.list.clipboard")
      TextEditor(text: $customPrompt)
        .flowFont(.callout)
        .scrollContentBackground(.hidden)
        .padding(10)
        .frame(minHeight: 120)
        .flowPanel()
      Text("For example: “List all open questions”, “Write a short protocol with decisions and tasks” or “Translate into English”.")
        .flowFont(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { customPromptJobID = nil }
          .buttonStyle(.flowQuiet)
        Button("Run") {
          if let id = customPromptJobID { store.send(.aiRun(id, styleID: "", instruction: customPrompt)) }
          customPromptJobID = nil
        }
        .buttonStyle(.flowPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 520)
    .background(FlowBackdrop())
  }

  private func renameSpeaker(job: FileTranscriptionFeature.Job, speaker: Int) {
    let alert = NSAlert()
    alert.messageText = "Rename speaker"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = TranscriptExporter.speakerName(speaker, names: job.speakerNames) ?? ""
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      store.send(.renameSpeaker(job.id, speaker: speaker, name: field.stringValue))
    }
  }

  static func formatTitle(_ format: TranscriptExporter.Format) -> String {
    switch format {
    case .text: "Text (.txt)"
    case .markdown: "Markdown (.md)"
    case .srt: "Subtitles (.srt)"
    case .vtt: "Web subtitles (.vtt)"
    }
  }

  private func placeholder(_ text: String, symbol: String) -> some View {
    VStack(spacing: 10) {
      Image(systemName: symbol).flowFont(.largeTitle).foregroundStyle(.tertiary)
      Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(30)
  }

  private func progressView(_ title: String, _ fraction: Double?) -> some View {
    VStack(spacing: 12) {
      if let fraction {
        ProgressView(value: fraction).frame(width: 260)
        Text("\(title) \(Int(fraction * 100)) %").foregroundStyle(.secondary)
      } else {
        ProgressView()
        Text(title).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct JobRow: View {
  let job: FileTranscriptionFeature.Job

  var body: some View {
    HStack(spacing: 10) {
      statusIcon.frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(job.name).lineLimit(1).truncationMode(.middle)
        Text(detail).flowFont(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch job.status {
    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
    case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
    case .loading, .transcribing, .diarizing: ProgressView().controlSize(.small)
    }
  }

  private var detail: String {
    let duration = job.duration.map { TranscriptExporter.clock($0) } ?? "–"
    switch job.status {
    case .queued: return "\(duration) · queued"
    case let .transcribing(fraction): return "\(duration) · \(Int(fraction * 100)) %"
    case .loading: return "\(duration) · reading"
    case .diarizing: return "\(duration) · speakers"
    case .done: return "\(duration) · \(job.segments.count) segments"
    case .failed: return "\(duration) · failed"
    case .cancelled: return "\(duration) · cancelled"
    }
  }
}

private struct SegmentRow: View {
  let segment: TranscriptSegment
  let speakerName: String?
  let isPlaying: Bool
  let onPlay: () -> Void
  let onEdit: (String) -> Void
  @State private var text: String = ""

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Button(action: onPlay) {
        HStack(spacing: 4) {
          Image(systemName: isPlaying ? "stop.fill" : "play.fill").flowFont(.caption2)
          Text(TranscriptExporter.clock(segment.start)).flowFont(.caption, monospacedDigit: true)
        }
        .frame(width: 64, alignment: .leading)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
      .help("Play from here")
      .accessibilityLabel(isPlaying ? "Stop playback" : "Play from \(TranscriptExporter.clock(segment.start))")
      VStack(alignment: .leading, spacing: 3) {
        if let speakerName {
          Text(speakerName).flowFont(.caption, weight: .semibold).foregroundStyle(.tint)
        }
        TextField("", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .flowFont(.body)
          .onSubmit { onEdit(text) }
          .onChange(of: text) { _, newValue in
            if newValue != segment.text { onEdit(newValue) }
          }
      }
    }
    .onAppear { text = segment.text }
    .onChange(of: segment.text) { _, newValue in
      if newValue != text { text = newValue }
    }
  }
}
