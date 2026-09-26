import ComposableArchitecture
import HexCore
import SwiftUI

/// Dictation box content (plan 5.8): header, format toolbar, editor, footer.
struct DictationBoxView: View {
  @Bindable var store: StoreOf<DictationBoxFeature>
  let transcription: StoreOf<TranscriptionFeature>

  var body: some View {
    VStack(spacing: 0) {
      header
      if store.phase == .learning {
        learnView
      } else {
        toolbar
        BoxTextEditor(store: store)
          .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
          .overlay(alignment: .topLeading) {
            if store.text.length == 0 {
              Text(placeholder)
                .font(Font(store.baseFont))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 19)
                .padding(.vertical, 12)
                .allowsHitTesting(false)
            }
          }
        footer
      }
    }
    .frame(minWidth: 480, minHeight: 260)
    .confirmationDialog(
      "Diktat verwerfen?",
      isPresented: $store.isConfirmingDiscard,
      titleVisibility: .visible
    ) {
      Button("Verwerfen", role: .destructive) { store.send(.discardConfirmed) }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("\(store.wordCount) Wörter gehen verloren.")
    }
  }

  private var placeholder: String {
    if transcription.isRecording { return "Sprechen …" }
    if transcription.isTranscribing { return "Wird transkribiert …" }
    return "Diktat-Taste drücken und sprechen. Befehle wie „neuer Absatz“ oder „Punkt“ funktionieren hier."
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      Label(store.mode == .literal ? "Literal" : "Normal", systemImage: store.mode == .literal ? "paragraphsign" : "waveform")
        .font(.callout.weight(.semibold))
        .labelStyle(.titleAndIcon)
      Text("·").foregroundStyle(.tertiary)
      Text(modelName)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Menu {
        Button("Automatisch") { store.send(.setLanguage(nil)) }
        Button("Deutsch") { store.send(.setLanguage("de")) }
        Button("English") { store.send(.setLanguage("en")) }
      } label: {
        Text(store.language.uppercased()).font(.callout.monospaced())
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Sprache dieser Box")
      Spacer()
      statusIndicator
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .glassEffect(.regular, in: .rect(cornerRadius: 0))
  }

  private var modelName: String {
    let model = transcription.hexSettings.selectedModel
    return (try? LocalASRModelCatalog.descriptor(named: model))?.displayName ?? model
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if transcription.isRecording {
      HStack(spacing: 6) {
        Circle().fill(.red).frame(width: 8, height: 8)
        LevelBars(level: transcription.meter.averagePower)
        if let start = transcription.recordingStartTime {
          TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Duration.seconds(context.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
              .font(.callout.monospacedDigit())
          }
        }
      }
      .accessibilityLabel("Aufnahme läuft")
    } else if transcription.isTranscribing {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Transkribiert").font(.callout).foregroundStyle(.secondary)
      }
    } else if store.spellingMode {
      Label("Buchstabieren", systemImage: "character.cursor.ibeam")
        .font(.callout)
        .foregroundStyle(.tint)
    }
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 6) {
      Menu {
        ForEach(BoxTextStyle.fontChoices, id: \.name) { choice in
          Button(choice.title) { store.send(.setFont(choice.name)) }
        }
      } label: {
        Text(BoxTextStyle.fontChoices.first { $0.name == store.hexSettings.boxFontName }?.title ?? store.hexSettings.boxFontName)
          .font(.callout)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Schriftart")

      Menu {
        ForEach([11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28], id: \.self) { size in
          Button("\(size) pt") { store.send(.setFontSize(Double(size))) }
        }
      } label: {
        Text("\(Int(store.hexSettings.boxFontSize)) pt").font(.callout.monospacedDigit())
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Schriftgröße")

      Divider().frame(height: 18)

      toolButton("bold", "Fett") { store.send(.toggleBold) }
      toolButton("italic", "Kursiv") { store.send(.toggleItalic) }
      toolButton("textformat.size.larger", "Überschrift") { store.send(.toggleHeading) }
      toolButton("list.bullet", "Aufzählung") { store.send(.toggleBullets) }
      toolButton("quote.opening", "Anführungszeichen um Markierung") { store.send(.quoteSelection) }
      toolButton("textformat", "Groß/klein umschalten") { store.send(.cycleCase) }
      toolButton("character.cursor.ibeam", "Buchstabiermodus: nächstes Diktat als Buchstaben", active: store.spellingMode) {
        store.send(.toggleSpellingMode)
      }

      Spacer()

      Picker("Format", selection: Binding(
        get: { store.hexSettings.boxOutputFormat },
        set: { store.send(.setFormat($0)) }
      )) {
        Text("Rich Text").tag(OutputFormat.richText)
        Text("Markdown").tag(OutputFormat.markdown)
        Text("Klartext").tag(OutputFormat.plainText)
      }
      .labelsHidden()
      .fixedSize()
      .help("Was beim Einfügen übertragen wird")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .controlSize(.small)
  }

  private func toolButton(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: 22, height: 20)
    }
    .buttonStyle(.glass)
    .tint(active ? .accentColor : nil)
    .help(help)
    .accessibilityLabel(help)
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 10) {
      Text(store.lastAction.isEmpty ? " " : store.lastAction)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Text("\(store.wordCount) Wörter")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
      Button {
        store.send(.discardTapped)
      } label: {
        Image(systemName: "xmark")
          .font(.body.weight(.semibold))
          .frame(width: 30, height: 22)
      }
      .buttonStyle(.glass)
      .help("Verwerfen")
      .accessibilityLabel("Verwerfen")

      Button {
        store.send(.confirmTapped)
      } label: {
        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .frame(width: 30, height: 22)
      }
      .buttonStyle(.glassProminent)
      .help(store.targetAppName.map { "In \($0) einfügen" } ?? "Einfügen")
      .accessibilityLabel("Einfügen")
      .disabled(store.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  // MARK: Learning

  private var learnView: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(store.learnCandidates.count) Korrektur\(store.learnCandidates.count == 1 ? "" : "en") ins Lexikon übernehmen?")
        .font(.headline)
      Text("Die Variante links wird künftig automatisch durch die Schreibweise rechts ersetzt.")
        .font(.caption)
        .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach($store.learnCandidates) { $candidate in
            Toggle(isOn: $candidate.isSelected) {
              HStack(spacing: 6) {
                Text(candidate.original.isEmpty ? "(neu)" : candidate.original).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Text(candidate.replacement).fontWeight(.medium)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Nicht jetzt") { store.send(.learnSkipped) }
          .buttonStyle(.glass)
        Button("Übernehmen") { store.send(.learnConfirmed) }
          .buttonStyle(.glassProminent)
          .disabled(!store.learnCandidates.contains(where: \.isSelected))
      }
    }
    .padding(16)
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

/// Five animated level bars (mint) for the recording indicator.
struct LevelBars: View {
  let level: Double

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0 ..< 5, id: \.self) { index in
        let threshold = Double(index) / 5
        let normalized = min(max(level * 4, 0), 1)
        Capsule()
          .fill(normalized > threshold ? Color.accentColor : Color.secondary.opacity(0.3))
          .frame(width: 3, height: 5 + CGFloat(index % 3) * 3 + (normalized > threshold ? 4 : 0))
      }
    }
    .frame(height: 16)
    .animation(.easeOut(duration: 0.12), value: level)
  }
}
