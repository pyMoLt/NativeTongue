import ComposableArchitecture
import HexCore
import SwiftUI

/// First-launch sheet (plan 5.10): welcome → permissions → model → word packs → test dictation.
struct OnboardingView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var step = 0
  @State private var isImporterPresented = false
  private let recommendedModel = "openai_whisper-large-v3-v20240930_turbo"

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        ForEach(0 ..< 5, id: \.self) { index in
          Capsule()
            .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.25))
            .frame(height: 4)
        }
      }
      .padding([.horizontal, .top], 24)

      Group {
        switch step {
        case 0: welcome
        case 1: permissions
        case 2: model
        case 3: packs
        default: tryIt
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(24)

      HStack {
        if step > 0 {
          Button("Back") { withAnimation { step -= 1 } }.buttonStyle(.glass)
        }
        Spacer()
        Button("Skip") { store.send(.finishOnboarding) }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
        Button(step == 4 ? "Done" : "Continue") {
          if step == 4 { store.send(.finishOnboarding) } else { withAnimation { step += 1 } }
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(20)
    }
    .frame(width: 620, height: 470)
    .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
      if case let .success(urls) = result { store.send(.lexicon(.importPacks(urls))) }
    }
  }

  private func title(_ text: String, _ subtitle: String, symbol: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(.tint)
        .frame(width: 54, height: 54)
        .glassEffect(.regular.tint(.accentColor.opacity(0.2)), in: .rect(cornerRadius: 14))
      VStack(alignment: .leading, spacing: 3) {
        Text(text).font(.title2.weight(.semibold))
        Text(subtitle).foregroundStyle(.secondary)
      }
    }
    .padding(.bottom, 16)
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 12) {
      title("Welcome to \(AppBrand.name)", "Private dictation in German and English – entirely on this Mac.", symbol: "paragraphsign")
      bullet("lock.shield", "No cloud: recording, recognition and correction stay on your Mac.")
      bullet("waveform", "Normal mode: natural text for chats and AI agents, inserted directly.")
      bullet("paragraphsign", "Literal mode: only spoken punctuation, with a dictation box for demanding texts.")
      bullet("character.book.closed", "Domain vocabulary (medicine, Latin, technology) is corrected and suggested.")
    }
  }

  private var permissions: some View {
    VStack(alignment: .leading, spacing: 12) {
      title("Permissions", "Three permissions let you dictate into any app.", symbol: "hand.raised")
      permissionRow("Microphone", "to record", store.microphonePermission) { store.send(.settings(.requestMicrophone)) }
      permissionRow("Accessibility", "to insert text into other apps", store.accessibilityPermission) { store.send(.settings(.requestAccessibility)) }
      permissionRow("Input Monitoring", "for the global dictation key", store.inputMonitoringPermission) { store.send(.settings(.requestInputMonitoring)) }
    }
  }

  private var model: some View {
    let installed = store.settings.modelDownload.availableModels.first { $0.name == recommendedModel }?.isDownloaded ?? false
    let downloading = store.settings.modelDownload.downloadingModelName == recommendedModel
    return VStack(alignment: .leading, spacing: 12) {
      title("Install a model", "Recommended: Whisper Large v3 Turbo – best result in the literal test (14/14 commands).", symbol: "cpu")
      Card {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Whisper Large v3 Turbo").font(.headline)
            Text("\((try? LocalASRModelCatalog.descriptor(named: recommendedModel))?.storageSize ?? "~1.64 GB") · German and English, automatic language").font(.caption).foregroundStyle(.secondary)
            LocalASRLiteralRating.reliable.badge
          }
          Spacer()
          if installed {
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          } else if downloading {
            ProgressView(value: store.settings.modelDownload.downloadProgress).frame(width: 120)
          } else {
            Button {
              store.send(.settings(.modelDownload(.selectModel(recommendedModel))))
              store.send(.settings(.modelDownload(.downloadModel(recommendedModel))))
            } label: {
              Label("Install", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glassProminent)
          }
        }
      }
      Text("More models (Parakeet, Qwen, Canary, Cohere, Apple) are available under Models. Nothing is downloaded unless you choose it.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var packs: some View {
    VStack(alignment: .leading, spacing: 12) {
      title("Word packs (optional)", "Domain vocabularies (medicine, anatomy, technology) for suggestions and corrections.", symbol: "character.book.closed")
      Text("Import word pack JSON files. They stay on this Mac and are never sent to the speech model.")
        .foregroundStyle(.secondary)
      Button {
        isImporterPresented = true
      } label: {
        Label("Import word packs…", systemImage: "square.and.arrow.down")
      }
      .buttonStyle(.glass)
      if !store.lexicon.packs.isEmpty {
        ForEach(store.lexicon.packs) { pack in
          Label("\(LexiconView.packName(pack.id)) · \(pack.entryCount.formatted()) terms", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
    }
  }

  private var tryIt: some View {
    VStack(alignment: .leading, spacing: 12) {
      title("Try it", "Hold the dictation key (\(DictationHomeView.describe(store.hexSettings.hotkey))) and say:", symbol: "mic")
      Text("“This is a first test period\n[short pause] new paragraph [short pause]\nIt works period”")
        .font(.system(.title3, design: .serif))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
      Text("In Literal mode the dictation box opens. Hover over a word to see suggestions, then insert with ✓.")
        .foregroundStyle(.secondary)
      Button("Switch to Literal mode") { store.send(.settings(.setDictationMode(.literal))) }
        .buttonStyle(.glass)
        .disabled(store.hexSettings.dictationMode == .literal)
    }
  }

  private func bullet(_ symbol: String, _ text: String) -> some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: symbol).foregroundStyle(.tint)
    }
    .font(.body)
  }

  private func permissionRow(_ title: String, _ reason: String, _ status: PermissionStatus, request: @escaping () -> Void) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if status == .granted {
        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      } else {
        Button("Allow", action: request).buttonStyle(.glass)
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
  }
}
