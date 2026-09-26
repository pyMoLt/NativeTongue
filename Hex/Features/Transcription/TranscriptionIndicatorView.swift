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
    case prewarming
  }

  var status: Status
  var meter: Meter
  var mode: DictationMode = .normal
  var recordingStart: Date?
  var message: String?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: mode == .literal ? "paragraphsign" : "waveform")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(status == .recording ? Color.red : Color.accentColor)
        .symbolEffect(.pulse, isActive: status == .recording)
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
        Text(message ?? "Transkribiert …").font(.system(size: 13, weight: .medium))
      case .prewarming:
        ProgressView().controlSize(.small)
        Text("Modell wird geladen …").font(.system(size: 13, weight: .medium))
      case .optionKeyPressed, .hidden:
        EmptyView()
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
    .frame(maxWidth: 520)
    .glassEffect(status == .recording ? .regular.tint(.red.opacity(0.12)) : .regular, in: .capsule)
    .opacity(status == .hidden ? 0 : 1)
    .scaleEffect(status == .hidden ? 0.85 : 1)
    .animation(.smooth(duration: 0.25), value: status)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
    .enableInjection()
  }

  private var accessibilityText: String {
    switch status {
    case .recording: "Aufnahme läuft"
    case .transcribing: "Transkribiert"
    case .prewarming: "Modell wird geladen"
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
