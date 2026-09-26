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
          Button("Zurück") { withAnimation { step -= 1 } }.buttonStyle(.glass)
        }
        Spacer()
        Button("Überspringen") { store.send(.finishOnboarding) }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
        Button(step == 4 ? "Fertig" : "Weiter") {
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
      title("Willkommen bei Local ASR", "Diktieren auf Deutsch und Englisch – vollständig auf diesem Mac.", symbol: "paragraphsign")
      bullet("lock.shield", "Keine Cloud: Aufnahme, Erkennung und Korrektur bleiben lokal.")
      bullet("waveform", "Normal-Modus: natürlicher Text für Chats und KI-Agenten, direkt eingefügt.")
      bullet("paragraphsign", "Literal-Modus: nur gesprochene Satzzeichen – wie Dragon Medical, mit Diktierbox.")
      bullet("character.book.closed", "Fachwörter aus Medizin, Latein und Technik werden erkannt und vorgeschlagen.")
    }
  }

  private var permissions: some View {
    VStack(alignment: .leading, spacing: 12) {
      title("Berechtigungen", "Drei Freigaben braucht die App, damit Diktieren überall funktioniert.", symbol: "hand.raised")
      permissionRow("Mikrofon", "zum Aufnehmen", store.microphonePermission) { store.send(.settings(.requestMicrophone)) }
      permissionRow("Bedienungshilfen", "zum Einfügen in andere Apps", store.accessibilityPermission) { store.send(.settings(.requestAccessibility)) }
      permissionRow("Eingabeüberwachung", "für die globale Diktat-Taste", store.inputMonitoringPermission) { store.send(.settings(.requestInputMonitoring)) }
    }
  }

  private var model: some View {
    let installed = store.settings.modelDownload.availableModels.first { $0.name == recommendedModel }?.isDownloaded ?? false
    let downloading = store.settings.modelDownload.downloadingModelName == recommendedModel
    return VStack(alignment: .leading, spacing: 12) {
      title("Modell installieren", "Empfehlung: Whisper Large v3 Turbo – bestes Ergebnis im Literal-Test (14/14 Befehle).", symbol: "cpu")
      Card {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Whisper Large v3 Turbo").font(.headline)
            Text("\((try? LocalASRModelCatalog.descriptor(named: recommendedModel))?.storageSize ?? "~1.64 GB") · Deutsch und Englisch, Sprache automatisch").font(.caption).foregroundStyle(.secondary)
            LocalASRLiteralRating.reliable.badge
          }
          Spacer()
          if installed {
            Label("Installiert", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          } else if downloading {
            ProgressView(value: store.settings.modelDownload.downloadProgress).frame(width: 120)
          } else {
            Button {
              store.send(.settings(.modelDownload(.selectModel(recommendedModel))))
              store.send(.settings(.modelDownload(.downloadModel(recommendedModel))))
            } label: {
              Label("Installieren", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glassProminent)
          }
        }
      }
      Text("Weitere Modelle (Parakeet, Qwen, Canary, Cohere, Apple) findest du später unter „Modelle“. Heruntergeladen wird nur, was du hier oder dort auswählst.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var packs: some View {
    VStack(alignment: .leading, spacing: 12) {
      title("Wortpakete (optional)", "Diagnosen, Wirkstoffe, Anatomie und Technikbegriffe für Vorschläge und Korrektur.", symbol: "character.book.closed")
      Text("Importiere die JSON-Dateien aus deinem Ordner „06-wortlisten/packs“. Sie bleiben lokal und werden nie an das Sprachmodell geschickt.")
        .foregroundStyle(.secondary)
      Button {
        isImporterPresented = true
      } label: {
        Label("Wortpakete importieren…", systemImage: "square.and.arrow.down")
      }
      .buttonStyle(.glass)
      if !store.lexicon.packs.isEmpty {
        ForEach(store.lexicon.packs) { pack in
          Label("\(LexiconView.packName(pack.id)) · \(pack.entryCount.formatted()) Begriffe", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
    }
  }

  private var tryIt: some View {
    VStack(alignment: .leading, spacing: 12) {
      title("Probediktat", "Halte die Diktat-Taste (\(DictationHomeView.describe(store.hexSettings.hotkey))) und sprich:", symbol: "mic")
      Text("„Befund unauffällig Punkt\n[kurze Pause] neuer Absatz [kurze Pause]\nKeine Hinweise auf eine Thrombose Punkt“")
        .font(.system(.title3, design: .serif))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
      Text("Im Literal-Modus öffnet sich die Diktierbox. Fahre mit der Maus über ein Wort, um Vorschläge zu sehen, und füge mit ✓ ein.")
        .foregroundStyle(.secondary)
      Button("Literal-Modus einschalten") { store.send(.settings(.setDictationMode(.literal))) }
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
        Label("Erteilt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      } else {
        Button("Erlauben", action: request).buttonStyle(.glass)
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
  }
}
