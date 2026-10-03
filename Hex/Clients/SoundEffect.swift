//
//  SoundEffect.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import SwiftUI

// Thank you. Never mind then.What a beautiful idea.
public enum SoundEffect: String, CaseIterable {
  case pasteTranscript
  case startRecording
  case stopRecording
  case cancel

  public var fileName: String {
    self.rawValue
  }

  var fileExtension: String {
    "mp3"
  }
}

@DependencyClient
public struct SoundEffectsClient {
  public var play: @Sendable (SoundEffect) -> Void
  public var stop: @Sendable (SoundEffect) -> Void
  public var stopAll: @Sendable () -> Void
  public var preloadSounds: @Sendable () async -> Void
  public var setEnabled: @Sendable (Bool) async -> Void
}

extension SoundEffectsClient: DependencyKey {
  public static var liveValue: SoundEffectsClient {
    let live = SoundEffectsClientLive()
    return SoundEffectsClient(
      play: { soundEffect in
        Task { await live.play(soundEffect) }
      },
      stop: { soundEffect in
        Task { await live.stop(soundEffect) }
      },
      stopAll: {
        Task { await live.stopAll() }
      },
      preloadSounds: {
        await live.preloadSounds()
      },
      setEnabled: { enabled in
        await live.setEnabled(enabled)
      }
    )
  }
}

public extension DependencyValues {
  var soundEffects: SoundEffectsClient {
    get { self[SoundEffectsClient.self] }
    set { self[SoundEffectsClient.self] = newValue }
  }
}

actor SoundEffectsClientLive {
  private let logger = HexLog.sound
  private let baselineVolume = HexSettings.baseSoundEffectsVolume

  private var engine: AVAudioEngine?
  @Shared(.hexSettings) var hexSettings: HexSettings
  private var playerNodes: [SoundEffect: AVAudioPlayerNode] = [:]
  private var audioBuffers: [SoundEffect: AVAudioPCMBuffer] = [:]
  private var idleShutdownTask: Task<Void, Never>?
  /// Comfortably longer than any sound effect, short enough that an idle Hex doesn't keep
  /// an output IOProc (and coreaudiod) running around the clock (#209).
  private static let idleShutdownDelay: Duration = .seconds(10)

  func play(_ soundEffect: SoundEffect) {
    guard hexSettings.soundEffectsEnabled else { return }
    guard let buffer = audioBuffers[soundEffect] else {
      logger.error("Requested sound \(soundEffect.rawValue) not preloaded")
      return
    }
    prepareEngineIfNeeded()
    guard let player = playerNodes[soundEffect] else { return }
    let clampedVolume = min(max(hexSettings.soundEffectsVolume, 0), baselineVolume)
    player.volume = Float(clampedVolume)
    player.stop()
    player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    player.play()
    scheduleIdleShutdown()
  }

  /// Stops the output engine shortly after playback so it doesn't run while idle.
  /// Restarting it on the next play costs only a few milliseconds.
  private func scheduleIdleShutdown() {
    idleShutdownTask?.cancel()
    idleShutdownTask = Task {
      try? await Task.sleep(for: Self.idleShutdownDelay)
      guard !Task.isCancelled else { return }
      stopEngineIfNeeded()
    }
  }

  func stop(_ soundEffect: SoundEffect) {
    playerNodes[soundEffect]?.stop()
  }

  func stopAll() {
    playerNodes.values.forEach { $0.stop() }
  }

  func preloadSounds() async {
    guard !isSetup else { return }

    for soundEffect in SoundEffect.allCases {
      loadSound(soundEffect)
    }

    isSetup = true
  }

  func setEnabled(_: Bool) async {
    await preloadSounds()

    // No prewarm on enable: play() starts the engine lazily, and an idle prewarm would
    // just be shut down again by the idle timer.
    if !hexSettings.soundEffectsEnabled {
      stopAll()
      idleShutdownTask?.cancel()
      stopEngineIfNeeded()
    }
  }

  private var isSetup = false

  private func loadSound(_ soundEffect: SoundEffect) {
    guard let url = Bundle.main.url(
      forResource: soundEffect.fileName,
      withExtension: soundEffect.fileExtension
    ) else {
      logger.error("Missing sound resource \(soundEffect.fileName).\(soundEffect.fileExtension)")
      return
    }

    do {
      let file = try AVAudioFile(forReading: url)
      let frameCount = AVAudioFrameCount(file.length)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        logger.error("Failed to allocate buffer for \(soundEffect.rawValue)")
        return
      }
      try file.read(into: buffer)
      audioBuffers[soundEffect] = buffer

    } catch {
      logger.error("Failed to load sound \(soundEffect.rawValue): \(error.localizedDescription)")
    }
  }

  private func prepareEngineIfNeeded() {
    if engine == nil {
      let newEngine = AVAudioEngine()
      for (effect, buffer) in audioBuffers {
        let player = AVAudioPlayerNode()
        newEngine.attach(player)
        newEngine.connect(player, to: newEngine.mainMixerNode, format: buffer.format)
        playerNodes[effect] = player
      }
      engine = newEngine
    }
    guard let engine, !engine.isRunning else { return }
    engine.prepare()
    if #available(macOS 13.0, *) {
      engine.isAutoShutdownEnabled = false
    }
    do {
      try engine.start()
    } catch {
      logger.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
    }
  }

  private func stopEngineIfNeeded() {
    guard let engine else { return }
    playerNodes.values.forEach { $0.stop(); engine.detach($0) }
    playerNodes.removeAll()
    engine.stop()
    self.engine = nil
    logger.debug("Sound effects engine stopped")
  }

  deinit {
    if let engine {
      playerNodes.values.forEach {
        $0.stop()
        engine.detach($0)
      }
      engine.stop()
    }
  }
}
