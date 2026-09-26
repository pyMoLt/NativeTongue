import ComposableArchitecture
import HexCore
import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
  @Bindable var store: StoreOf<FileTranscriptionFeature>
  @State private var isDropTargeted = false

  var body: some View {
    HSplitView {
      queue
        .frame(minWidth: 250, idealWidth: 280, maxWidth: 360)
      editor
        .frame(minWidth: 420, maxWidth: .infinity)
    }
    .task { store.send(.task) }
    .fileImporter(
      isPresented: $store.isImporterPresented,
      allowedContentTypes: [.audio, .movie],
      allowsMultipleSelection: true
    ) { result in
      if case let .success(urls) = result { store.send(.addFiles(urls)) }
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
    VStack(alignment: .leading, spacing: 12) {
      PageHeader(title: "Files", subtitle: "Transcribe recordings on this Mac", symbol: "doc.badge.waveform")
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
      .overlay {
        if store.jobs.isEmpty {
          Text("No files yet").foregroundStyle(.tertiary)
        }
      }
    }
    .padding(16)
  }

  private var dropZone: some View {
    Button {
      store.send(.binding(.set(\.isImporterPresented, true)))
    } label: {
      VStack(spacing: 6) {
        Image(systemName: "square.and.arrow.down.on.square").font(.title2)
        Text("Drop audio or video files here").font(.callout.weight(.medium))
        Text("or click to choose · m4a, mp3, wav, aiff, mp4, mov").font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 18)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
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
    VStack(alignment: .leading, spacing: 6) {
      Picker("Mode", selection: $store.modeForFiles) {
        Text("Normal").tag(DictationMode.normal)
        Text("Literal").tag(DictationMode.literal)
      }
      .pickerStyle(.segmented)
      HStack {
        Toggle("Separate speakers", isOn: $store.diarizeByDefault)
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(!store.isDiarizationInstalled)
        Spacer()
        if !store.isDiarizationInstalled {
          if store.isInstallingDiarization {
            ProgressView(value: store.diarizationProgress).frame(width: 70)
          } else {
            Button("Install…") { store.send(.installDiarization) }
              .buttonStyle(.glass)
              .controlSize(.small)
              .help("Downloads the speaker separation models once. Nothing else is downloaded.")
          }
        }
      }
      .font(.callout)
      Text("Applies to files added next. Model: \((try? LocalASRModelCatalog.descriptor(named: store.hexSettings.selectedModel))?.displayName ?? "none")")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Editor

  @ViewBuilder
  private var editor: some View {
    if let job = store.selectedJob {
      VStack(spacing: 0) {
        editorHeader(job)
        Divider()
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
      placeholder("Choose or drop a file", symbol: "doc.badge.waveform")
    }
  }

  private func editorHeader(_ job: FileTranscriptionFeature.Job) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(job.name).font(.headline).lineLimit(1)
        Text([job.duration.map { TranscriptExporter.clock($0) }, job.mode == .literal ? "Literal" : "Normal",
              job.diarize ? "speakers separated" : nil].compactMap { $0 }.joined(separator: " · "))
          .font(.caption)
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
    .buttonStyle(.glass)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
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
      Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
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
        Text(detail).font(.caption).foregroundStyle(.secondary)
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
          Image(systemName: isPlaying ? "stop.fill" : "play.fill").font(.caption2)
          Text(TranscriptExporter.clock(segment.start)).font(.caption.monospacedDigit())
        }
        .frame(width: 64, alignment: .leading)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
      .help("Play from here")
      .accessibilityLabel(isPlaying ? "Stop playback" : "Play from \(TranscriptExporter.clock(segment.start))")
      VStack(alignment: .leading, spacing: 3) {
        if let speakerName {
          Text(speakerName).font(.caption.weight(.semibold)).foregroundStyle(.tint)
        }
        TextField("", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.body)
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
