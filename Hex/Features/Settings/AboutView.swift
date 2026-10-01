import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

/// About: version, privacy, settings export/import, diagnostics, licenses (plan 5.10/5.13).
struct AboutView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var showingChangelog = false

  private var version: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(short) (\(build))"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 16) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 72, height: 72)
          VStack(alignment: .leading, spacing: 4) {
            Text(AppBrand.name).font(.largeTitle.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Label("Private dictation – audio never leaves this Mac", systemImage: "lock.shield")
              .font(.callout)
              .foregroundStyle(.tint)
          }
          Spacer()
          Button("Changelog") { showingChangelog = true }
            .buttonStyle(.glass)
        }

        Card(title: "Settings & vocabulary", systemImage: "arrow.up.arrow.down.square") {
          Text("Save all settings and your vocabulary to one file, or load them on another Mac. Word packs are not included, only which ones are active.")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button("Export…") { store.send(.exportSettings) }
            Button("Import…") { store.send(.importSettings) }
          }
          .buttonStyle(.glass)
        }

        Card(title: "Diagnostics", systemImage: "stethoscope") {
          Toggle("Record local diagnostics", isOn: Binding(
            get: { store.hexSettings.diagnosticsEnabled },
            set: { value in store.$hexSettings.withLock { $0.diagnosticsEnabled = value } }
          ))
          .toggleStyle(.switch)
          Text("Writes only metrics (duration, model, number of utterances and commands, error codes) to a file on this Mac – never text, audio or file names. Nothing is sent anywhere.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Show diagnostics file") { DiagnosticsStore.revealInFinder() }
            .buttonStyle(.glass)
            .disabled(!DiagnosticsStore.exists)
        }

        Card(title: "Acknowledgements", systemImage: "heart.text.square") {
          VStack(alignment: .leading, spacing: 6) {
            credit("Hex", "Kit Langton · MIT – the app this project started from")
            credit("WhisperKit", "Argmax · MIT · OpenAI Whisper models (MIT)")
            credit("FluidAudio", "FluidInference · Apache-2.0 · Parakeet, Canary (CC-BY-4.0), speaker separation")
            credit("speech-swift / MLX", "soniqo, Apple · Apache-2.0 / MIT · Qwen3-ASR (Apache-2.0), Cohere Transcribe (Apache-2.0)")
            credit("Apple SpeechAnalyzer", "on-device system component")
            credit("Word packs", "Wikidata (CC0), cspell-dicts (MIT), medical word lists (GPL-3.0, separate download), BfArM data (local use only)")
            credit("Composable Architecture, Sharing, Dependencies", "Point-Free · MIT")
          }
        }
      }
      .padding(LocalASRDesign.pagePadding)
    }
    .sheet(isPresented: $showingChangelog) { ChangelogView() }
  }

  private func credit(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.callout.weight(.semibold))
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Optional content-free metrics (`diagnostics/metrics.jsonl`).
enum DiagnosticsStore {
  static var url: URL? {
    guard !isTesting else { return nil }
    return try? URL.hexApplicationSupport.appendingPathComponent("diagnostics", isDirectory: true).appendingPathComponent("metrics.jsonl")
  }

  static var exists: Bool {
    url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
  }

  static func record(_ record: DiagnosticsRecord, enabled: Bool) {
    guard enabled, let url else { return }
    try? record.append(to: url)
  }

  static func revealInFinder() {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
