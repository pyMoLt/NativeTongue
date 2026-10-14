import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Reads the first audio track of any media file (m4a, mp3, wav, aiff, caf,
/// mp4/mov) as 16 kHz mono Float32 using AVAssetReader.
enum MediaAudioLoader {
  struct LoadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func loadSamples(from url: URL, sampleRate: Double = 16_000) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw LoadError(message: "The file has no audio track.")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw LoadError(message: "The audio track cannot be decoded.") }
    reader.add(output)
    guard reader.startReading() else {
      throw LoadError(message: reader.error?.localizedDescription ?? "The audio could not be read.")
    }
    // The whole signal is needed for pause segmentation and subtitle timing.
    // Reserving it up front avoids the growth copies (peak ≈ 2× the audio) and
    // the per-buffer temporary arrays (audit L6).
    var samples: [Float] = []
    if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
      samples.reserveCapacity(Int(seconds * sampleRate) + Int(sampleRate))
    }
    while let buffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      let count = length / MemoryLayout<Float>.size
      guard count > 0 else { continue }
      let start = samples.count
      samples.append(contentsOf: repeatElement(0, count: count))
      samples.withUnsafeMutableBytes { raw in
        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
      }
    }
    if reader.status == .failed {
      throw LoadError(message: reader.error?.localizedDescription ?? "The audio could not be read.")
    }
    return samples
  }

  static func duration(of url: URL) async -> Double? {
    guard let time = try? await AVURLAsset(url: url).load(.duration) else { return nil }
    let seconds = CMTimeGetSeconds(time)
    return seconds.isFinite ? seconds : nil
  }
}

enum AudioImportFileValidator {
  /// Local audio files and movies with an audio track (plan 5.11).
  static func isSupportedAudioFile(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .audio) || type.conforms(to: .movie)
  }
}
