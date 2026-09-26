import AppKit
import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import UniformTypeIdentifiers

private let fileLogger = HexLog.transcription

/// File transcription (plan 5.11): queue, progress, speaker separation,
/// editor with playback, TXT/MD/SRT/VTT export. Replaces the V1 audio import.
@Reducer
struct FileTranscriptionFeature {
  enum JobStatus: Equatable {
    case queued
    case loading
    case transcribing(Double)
    case diarizing
    case done
    case failed(String)
    case cancelled

    var isActive: Bool {
      switch self {
      case .loading, .transcribing, .diarizing: true
      default: false
      }
    }
  }

  struct Job: Equatable, Identifiable {
    let id: UUID
    var url: URL
    var name: String
    var duration: Double?
    var status: JobStatus = .queued
    var segments: [TranscriptSegment] = []
    var speakerNames: [Int: String] = [:]
    var diarize: Bool
    var mode: DictationMode

    var speakers: [Int] { Array(Set(segments.compactMap(\.speaker))).sorted() }
  }

  @ObservableState
  struct State: Equatable {
    var jobs: IdentifiedArrayOf<Job> = []
    var selectedJobID: Job.ID?
    var diarizeByDefault = false
    var modeForFiles: DictationMode = .normal
    var isDiarizationInstalled = false
    var isInstallingDiarization = false
    var diarizationProgress = 0.0
    var playingSegmentID: Int?
    var isImporterPresented = false
    var errorMessage: String?
    @Shared(.hexSettings) var hexSettings: HexSettings

    var selectedJob: Job? { selectedJobID.flatMap { jobs[id: $0] } }
    var isProcessing: Bool { jobs.contains { $0.status.isActive } }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case diarizationStatusLoaded(Bool)
    case addFiles([URL])
    case durationLoaded(Job.ID, Double?)
    case removeJob(Job.ID)
    case selectJob(Job.ID?)
    case processNext
    case jobStatus(Job.ID, JobStatus)
    case jobFinished(Job.ID, [TranscriptSegment])
    case cancelJob(Job.ID)
    case retryJob(Job.ID)
    case editSegment(Job.ID, segment: Int, text: String)
    case renameSpeaker(Job.ID, speaker: Int, name: String)
    case export(Job.ID, TranscriptExporter.Format)
    case copyAll(Job.ID)
    case play(Job.ID, segment: Int)
    case stopPlayback
    case playbackFinished
    case installDiarization
    case diarizationInstallProgress(Double)
    case diarizationInstallFinished(String?)
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.lexicon) var lexicon
  @Dependency(\.diarization) var diarization
  @Dependency(\.pasteboard) var pasteboard

  private enum CancelID { case processing, playback }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        return .run { [diarization] send in
          await send(.diarizationStatusLoaded(await diarization.isInstalled()))
        }

      case let .diarizationStatusLoaded(installed):
        state.isDiarizationInstalled = installed
        if !installed { state.diarizeByDefault = false }
        return .none

      case let .addFiles(urls):
        var effects: [Effect<Action>] = []
        for url in urls where AudioImportFileValidator.isSupportedAudioFile(url) {
          guard !state.jobs.contains(where: { $0.url == url && !$0.status.isActive && $0.status != .done }) else { continue }
          let job = Job(
            id: UUID(),
            url: url,
            name: url.lastPathComponent,
            diarize: state.diarizeByDefault && state.isDiarizationInstalled,
            mode: state.modeForFiles
          )
          state.jobs.append(job)
          if state.selectedJobID == nil { state.selectedJobID = job.id }
          effects.append(.run { send in await send(.durationLoaded(job.id, await MediaAudioLoader.duration(of: url))) })
        }
        if urls.contains(where: { !AudioImportFileValidator.isSupportedAudioFile($0) }) {
          state.errorMessage = "Some files were skipped because they contain no supported audio."
        }
        effects.append(.send(.processNext))
        return .merge(effects)

      case let .durationLoaded(id, duration):
        state.jobs[id: id]?.duration = duration
        return .none

      case let .removeJob(id):
        guard let job = state.jobs[id: id], !job.status.isActive else { return .none }
        state.jobs.remove(id: id)
        if state.selectedJobID == id { state.selectedJobID = state.jobs.first?.id }
        return .none

      case let .selectJob(id):
        state.selectedJobID = id
        return .none

      case .processNext:
        guard !state.isProcessing, let job = state.jobs.first(where: { $0.status == .queued }) else { return .none }
        state.jobs[id: job.id]?.status = .loading
        let settings = state.hexSettings
        let model = settings.selectedModel
        guard !model.isEmpty else {
          state.jobs[id: job.id]?.status = .failed("Choose and install a model first.")
          return .none
        }
        let biasingEnabled = settings.isBiasingEnabled(for: model)
        var request = FileTranscriptionRunner.Request(
          model: model,
          mode: job.mode,
          language: settings.outputLanguage,
          profile: settings.asrProfile,
          activePacks: settings.activeLexiconPacks,
          autoReplacePackTerms: settings.autoReplaceTermsLiteral,
          formatNumbers: settings.numberFormattingEnabled,
          englishCommands: settings.englishCommandsEnabled
        )
        let url = job.url
        let diarize = job.diarize
        return .run { [transcription, lexicon, diarization] send in
          let accessing = url.startAccessingSecurityScopedResource()
          defer { if accessing { url.stopAccessingSecurityScopedResource() } }
          do {
            let samples = try await MediaAudioLoader.loadSamples(from: url)
            if biasingEnabled { request.biasTerms = await lexicon.biasTerms(request.profile) }
            await send(.jobStatus(job.id, .transcribing(0)))
            let runner = FileTranscriptionRunner(transcribeSamples: transcription.transcribeSamples, corrector: lexicon.corrector)
            var segments = try await runner.run(samples: samples, request: request) { fraction in
              await send(.jobStatus(job.id, .transcribing(fraction)))
            }
            if diarize {
              await send(.jobStatus(job.id, .diarizing))
              let turns = try await diarization.diarize(samples)
              segments = SpeakerAssigner.normalizeOrder(SpeakerAssigner.assign(segments, turns: turns))
            }
            await send(.jobFinished(job.id, segments))
          } catch is CancellationError {
            await send(.jobStatus(job.id, .cancelled))
          } catch {
            fileLogger.error("File transcription failed: \(error.localizedDescription, privacy: .private)")
            await send(.jobStatus(job.id, .failed(error.localizedDescription)))
          }
          await send(.processNext)
        }
        .cancellable(id: CancelID.processing, cancelInFlight: true)

      case let .jobStatus(id, status):
        guard state.jobs[id: id] != nil else { return .none }
        if case .cancelled = state.jobs[id: id]?.status { return .none }
        state.jobs[id: id]?.status = status
        return .none

      case let .jobFinished(id, segments):
        state.jobs[id: id]?.segments = segments
        state.jobs[id: id]?.status = .done
        return .none

      case let .cancelJob(id):
        guard let job = state.jobs[id: id] else { return .none }
        if job.status.isActive {
          state.jobs[id: id]?.status = .cancelled
          return .merge(.cancel(id: CancelID.processing), .send(.processNext))
        }
        if job.status == .queued { state.jobs[id: id]?.status = .cancelled }
        return .none

      case let .retryJob(id):
        guard let job = state.jobs[id: id], !job.status.isActive else { return .none }
        state.jobs[id: id]?.status = .queued
        state.jobs[id: id]?.segments = []
        let canDiarize = state.isDiarizationInstalled
        state.jobs[id: id]?.diarize = job.diarize && canDiarize
        return .send(.processNext)

      case let .editSegment(id, segment, text):
        guard let index = state.jobs[id: id]?.segments.firstIndex(where: { $0.id == segment }) else { return .none }
        state.jobs[id: id]?.segments[index].text = text
        return .none

      case let .renameSpeaker(id, speaker, name):
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        state.jobs[id: id]?.speakerNames[speaker] = trimmed.isEmpty ? nil : trimmed
        return .none

      case let .export(id, format):
        guard let job = state.jobs[id: id], !job.segments.isEmpty else { return .none }
        let title = job.url.deletingPathExtension().lastPathComponent
        let content = TranscriptExporter.export(job.segments, format: format, speakerNames: job.speakerNames, title: title)
        return .run { _ in
          await MainActor.run {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(title).\(format.fileExtension)"
            panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
              try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
              fileLogger.error("Export failed: \(error.localizedDescription, privacy: .private)")
            }
          }
        }

      case let .copyAll(id):
        guard let job = state.jobs[id: id] else { return .none }
        let text = TranscriptExporter.plainText(job.segments, speakerNames: job.speakerNames)
        return .run { [pasteboard] _ in await pasteboard.copy(text) }

      case let .play(id, segmentID):
        guard let job = state.jobs[id: id], let segment = job.segments.first(where: { $0.id == segmentID }) else { return .none }
        if state.playingSegmentID == segmentID { return .send(.stopPlayback) }
        state.playingSegmentID = segmentID
        let url = job.url
        return .run { send in
          let finished = await TranscriptPlayer.shared.play(url: url, from: segment.start, until: segment.end)
          if finished { await send(.playbackFinished) }
        }
        .cancellable(id: CancelID.playback, cancelInFlight: true)

      case .stopPlayback:
        state.playingSegmentID = nil
        return .merge(.cancel(id: CancelID.playback), .run { _ in await TranscriptPlayer.shared.stop() })

      case .playbackFinished:
        state.playingSegmentID = nil
        return .none

      case .installDiarization:
        guard !state.isInstallingDiarization else { return .none }
        state.isInstallingDiarization = true
        state.diarizationProgress = 0
        return .run { [diarization] send in
          do {
            try await diarization.install { value in Task { await send(.diarizationInstallProgress(value)) } }
            await send(.diarizationInstallFinished(nil))
          } catch {
            await send(.diarizationInstallFinished(error.localizedDescription))
          }
        }

      case let .diarizationInstallProgress(value):
        state.diarizationProgress = value
        return .none

      case let .diarizationInstallFinished(error):
        state.isInstallingDiarization = false
        state.errorMessage = error
        return .run { [diarization] send in await send(.diarizationStatusLoaded(await diarization.isInstalled())) }
      }
    }
  }
}

/// Plays a stretch of the source file for the editor (plan 5.11).
@MainActor
final class TranscriptPlayer {
  static let shared = TranscriptPlayer()
  private var player: AVAudioPlayer?
  private var playerURL: URL?

  /// Returns `true` when playback reached `until`, `false` when stopped earlier.
  func play(url: URL, from start: Double, until end: Double) async -> Bool {
    do {
      if playerURL != url {
        player = try AVAudioPlayer(contentsOf: url)
        playerURL = url
      }
      guard let player else { return false }
      player.currentTime = max(0, start)
      player.play()
      while player.isPlaying, player.currentTime < end {
        try await Task.sleep(for: .milliseconds(50))
      }
      player.pause()
      return true
    } catch {
      player?.pause()
      return false
    }
  }

  func stop() {
    player?.pause()
  }
}
