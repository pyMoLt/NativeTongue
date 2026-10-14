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
    FlowPage("About", subtitle: "Version \(version) · private dictation – audio never leaves this Mac", symbol: "info.circle") {
      FlowBlock {
        HStack(spacing: 16) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
          VStack(alignment: .leading, spacing: 3) {
            Text(AppBrand.name).flowFont(.title2, weight: .bold, design: .rounded)
            Text("Version \(version)").flowFont(.callout).foregroundStyle(.secondary)
            Label("Private dictation – audio never leaves this Mac", systemImage: "lock.shield")
              .flowFont(.callout)
              .foregroundStyle(.tint)
          }
          Spacer()
          Button("Changelog") { showingChangelog = true }
            .buttonStyle(.flow)
        }
      }

      FlowGroup("Settings and vocabulary") {
        FlowRow("Move to another Mac", caption: "All settings and your vocabulary in one file. Word packs are not included, only which ones are active.") {
          HStack(spacing: 6) {
            Button("Export…") { store.send(.exportSettings) }
            Button("Import…") { store.send(.importSettings) }
          }
          .buttonStyle(.flow)
        }
      }

      FlowGroup("Diagnostics") {
        Toggle(isOn: Binding(
          get: { store.hexSettings.diagnosticsEnabled },
          set: { value in store.$hexSettings.withLock { $0.diagnosticsEnabled = value } }
        )) {
          FlowLabel("Record local diagnostics", caption: "Only metrics (duration, model, number of utterances and commands, error codes) in a file on this Mac – never text, audio or file names. Nothing is sent anywhere.")
        }
        FlowRow("Diagnostics file") {
          Button("Show in Finder") { DiagnosticsStore.revealInFinder() }
            .buttonStyle(.flow)
            .disabled(!DiagnosticsStore.exists)
        }
      }

      FlowGroup("Acknowledgements") {
        FlowBlock {
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
    .sheet(isPresented: $showingChangelog) {
      ChangelogView().flowThemed(store.hexSettings.appearance)
    }
  }

  private func credit(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).flowFont(.callout, weight: .semibold)
      Text(detail).flowFont(.caption).foregroundStyle(.secondary)
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
