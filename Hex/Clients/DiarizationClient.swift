import CoreML
import Dependencies
import DependenciesMacros
import FluidAudio
import Foundation
import HexCore

private let diarizationLogger = HexLog.models

/// Speaker separation for file transcription (FluidAudio pyannote segmentation
/// + WeSpeaker embeddings, Core ML). Models are downloaded only by `install`;
/// `diarize` works strictly offline from the installed files.
@DependencyClient
struct DiarizationClient {
  var isInstalled: @Sendable () async -> Bool = { false }
  var install: @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
  var remove: @Sendable () async throws -> Void
  var diarize: @Sendable (_ samples: [Float]) async throws -> [SpeakerTurn]
}

extension DiarizationClient: DependencyKey {
  static var liveValue: Self {
    let live = DiarizationLive()
    return Self(
      isInstalled: { await live.isInstalled() },
      install: { try await live.install(progress: $0) },
      remove: { try await live.remove() },
      diarize: { try await live.diarize($0) }
    )
  }

  static let testValue = Self(
    isInstalled: { false },
    install: { _ in },
    remove: {},
    diarize: { _ in [] }
  )
}

extension DependencyValues {
  var diarization: DiarizationClient {
    get { self[DiarizationClient.self] }
    set { self[DiarizationClient.self] = newValue }
  }
}

actor DiarizationLive {
  private var manager: DiarizerManager?

  static func directory() throws -> URL {
    try URL.hexModelsDirectory.appendingPathComponent("diarizer", isDirectory: true)
  }

  /// Locates the two compiled models anywhere below our directory.
  private func modelURLs() -> (segmentation: URL, embedding: URL)? {
    guard let root = try? Self.directory(),
          let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return nil }
    var segmentation: URL?, embedding: URL?
    for case let url as URL in enumerator {
      if url.lastPathComponent == ModelNames.Diarizer.segmentationFile { segmentation = url }
      if url.lastPathComponent == ModelNames.Diarizer.embeddingFile { embedding = url }
      if segmentation != nil, embedding != nil { break }
    }
    guard let segmentation, let embedding else { return nil }
    return (segmentation, embedding)
  }

  func isInstalled() -> Bool { modelURLs() != nil }

  /// Explicit, user-started download.
  func install(progress: @escaping @Sendable (Double) -> Void) async throws {
    let directory = try Self.directory().appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // The app keeps FluidAudio offline; only this explicit install may use the network.
    let previousOfflineMode = ModelHub.offlineMode
    ModelHub.offlineMode = false
    defer { ModelHub.offlineMode = previousOfflineMode }
    _ = try await DiarizerModels.download(to: directory) { value in
      progress(value.fractionCompleted)
    }
    guard isInstalled() else {
      throw NSError(domain: "Diarization", code: 1, userInfo: [NSLocalizedDescriptionKey: "The speaker separation download is incomplete."])
    }
    diarizationLogger.notice("Speaker separation models installed")
  }

  func remove() throws {
    manager?.cleanup()
    manager = nil
    let directory = try Self.directory()
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }

  func diarize(_ samples: [Float]) throws -> [SpeakerTurn] {
    if manager == nil {
      guard let urls = modelURLs() else {
        throw NSError(domain: "Diarization", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speaker separation is not installed. Install it under Models."])
      }
      ModelHub.offlineMode = true
      let models = try DiarizerModels.load(localSegmentationModel: urls.segmentation, localEmbeddingModel: urls.embedding)
      let manager = DiarizerManager()
      manager.initialize(models: models)
      self.manager = manager
    }
    guard let manager else { return [] }
    // Free the Core ML models after each file (at most one model family resident).
    defer { unload() }
    let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
    var indices: [String: Int] = [:]
    return result.segments.map { segment in
      if indices[segment.speakerId] == nil { indices[segment.speakerId] = indices.count }
      return SpeakerTurn(start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds), speaker: indices[segment.speakerId]!)
    }
  }

  /// Frees the Core ML models (one model family resident at a time).
  func unload() {
    manager?.cleanup()
    manager = nil
  }
}
