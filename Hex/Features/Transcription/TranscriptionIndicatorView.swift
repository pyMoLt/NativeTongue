import AppKit
import HexCore
import Inject
import SwiftUI

/// Recording HUD (plan 5.10): Liquid Glass capsule at the top centre —
/// mode glyph · five mint level bars · timer · status. Red only while recording.
struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject

  enum Status: Equatable {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    /// AI post-processing is running (shown as a small ✨, no text).
    case polishing
    /// Streaming mode: level bars, timer and the last few pending words.
    case streaming
    case prewarming
  }

  var status: Status
  var meter: Meter
  var mode: DictationMode = .normal
  var recordingStart: Date?
  var message: String?
  /// Shown next to the status when the AI result was not used (safety check or
  /// error): the original text was inserted instead.
  var showsWarning: Bool = false
  /// Streaming: recognised words not typed yet.
  var pendingText: String = ""

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: modeSymbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(status == .recording || status == .streaming ? Color.red : Color.accentColor)
        .symbolEffect(.pulse, isActive: status == .recording || status == .streaming)
      switch status {
      case .recording:
        LevelBars(level: meter.averagePower)
        if let recordingStart {
          TimelineView(.periodic(from: recordingStart, by: 1)) { context in
            Text(Duration.seconds(max(0, context.date.timeIntervalSince(recordingStart))).formatted(.time(pattern: .minuteSecond)))
              .font(.system(size: 13, weight: .medium).monospacedDigit())
          }
        }
      case .transcribing:
        ProgressView().controlSize(.small)
        Text(message ?? "Transcribing …").font(.system(size: 13, weight: .medium))
      case .streaming:
        LevelBars(level: meter.averagePower)
        if !pendingText.isEmpty {
          Text(pendingText)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: 240, alignment: .trailing)
        }
      case .polishing:
        Image(systemName: "sparkles")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .symbolEffect(.pulse)
      case .prewarming:
        ProgressView().controlSize(.small)
        Text("Loading model …").font(.system(size: 13, weight: .medium))
      case .optionKeyPressed, .hidden:
        EmptyView()
      }
      if showsWarning {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.orange)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
    .fixedSize()
    .glassEffect(status == .recording || status == .streaming ? .regular.tint(.red.opacity(0.12)) : .regular, in: .capsule)
    .opacity(status == .hidden && !showsWarning ? 0 : 1)
    .scaleEffect(status == .hidden && !showsWarning ? 0.85 : 1)
    .animation(.smooth(duration: 0.25), value: status)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
    .help("Esc cancels the current dictation")
    .enableInjection()
  }

  private var modeSymbol: String {
    switch mode {
    case .literal: "paragraphsign"
    case .streaming: "dot.radiowaves.left.and.right"
    case .normal: "waveform"
    }
  }

  private var accessibilityText: String {
    switch status {
    case .recording: "Recording"
    case .transcribing: "Transcribing"
    case .polishing: showsWarning ? "AI result not used" : "AI post-processing"
    case .streaming: "Streaming"
    case .prewarming: "Loading model"
    case .hidden, .optionKeyPressed: ""
    }
  }
}

#Preview("HUD") {
  VStack(spacing: 12) {
    TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.2, peakPower: 0.3), mode: .literal, recordingStart: Date())
    TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .prewarming, meter: .init(averagePower: 0, peakPower: 0))
  }
  .padding(40)
}
