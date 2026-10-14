import AppKit
import HexCore
import Inject
import SwiftUI

/// Recording HUD (plan 5.10): Liquid Glass capsule at the top centre —
/// mode glyph · five mint level bars · timer · status. Red only while recording.
struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject
  @Environment(\.flowTheme) private var theme

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
    HStack(spacing: 9) {
      leading
      switch status {
      case .recording:
        LevelBars(level: meter.averagePower)
        if let recordingStart {
          TimelineView(.periodic(from: recordingStart, by: 1)) { context in
            Text(Duration.seconds(max(0, context.date.timeIntervalSince(recordingStart))).formatted(.time(pattern: .minuteSecond)))
              .flowFont(size: 13, weight: .semibold, design: .rounded, monospacedDigit: true)
          }
        }
      case .transcribing:
        Text(message ?? "Transcribing").flowFont(size: 13, weight: .medium, design: .rounded)
          .foregroundStyle(.secondary)
      case .streaming:
        LevelBars(level: meter.averagePower)
        if !pendingText.isEmpty {
          Text(pendingText)
            .flowFont(size: 13, weight: .medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: 240, alignment: .trailing)
        }
      case .polishing:
        EmptyView()
      case .prewarming:
        Text("Loading model").flowFont(size: 13, weight: .medium, design: .rounded)
          .foregroundStyle(.secondary)
      case .optionKeyPressed, .hidden:
        EmptyView()
      }
      if showsWarning {
        Image(systemName: "exclamationmark.triangle.fill")
          .flowFont(size: 13, weight: .semibold)
          .foregroundStyle(.orange)
      }
    }
    .padding(.leading, 12)
    .padding(.trailing, 14)
    .frame(minHeight: 36 * theme.textScale)
    .fixedSize()
    .flowSurface(Capsule(), highlighted: isLive)
    .shadow(color: theme.accent.opacity(isLive ? 0.25 : 0.12), radius: 10, y: 3)
    .opacity(status == .hidden && !showsWarning ? 0 : 1)
    .scaleEffect(status == .hidden && !showsWarning ? 0.85 : 1)
    .animation(theme.animation(.smooth(duration: 0.25)), value: status)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
    .help("Esc cancels the current dictation")
    .enableInjection()
  }

  private var isLive: Bool { status == .recording || status == .streaming }

  /// Glowing dot while listening; spinner while working; ✨ for the AI.
  @ViewBuilder
  private var leading: some View {
    switch status {
    case .recording, .streaming:
      ZStack {
        Circle().fill(theme.accent.opacity(0.35)).frame(width: 16 * theme.textScale, height: 16 * theme.textScale)
          .blur(radius: 3)
        Circle().fill(LinearGradient(colors: [theme.accent, theme.companion], startPoint: .topLeading, endPoint: .bottomTrailing))
          .frame(width: 9 * theme.textScale, height: 9 * theme.textScale)
      }
      .frame(width: 16 * theme.textScale, height: 16 * theme.textScale)
    case .transcribing, .prewarming:
      ProgressView().controlSize(.small).tint(theme.accent)
    case .polishing:
      Image(systemName: "sparkles")
        .flowFont(size: 14, weight: .semibold)
        .foregroundStyle(theme.accent)
        .symbolEffect(.pulse)
    case .optionKeyPressed, .hidden:
      Image(systemName: modeSymbol)
        .flowFont(size: 13, weight: .semibold)
        .foregroundStyle(theme.accent)
    }
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
