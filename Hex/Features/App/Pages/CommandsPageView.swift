import ComposableArchitecture
import HexCore
import SwiftUI

/// „Befehle“: all spoken commands (plan appendix A) plus their switches.
struct CommandsPageView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var search = ""

  private struct Row: Identifiable {
    let id: String
    let action: String
    let german: [String]
    let english: [String]
    let modes: String
  }

  private struct Group: Identifiable {
    let id: String
    let title: String
    let note: String
    let rows: [Row]
  }

  private var groups: [Group] {
    func rows<T: Hashable>(_ table: [(CommandGrammar.Phrase, T)], modes: String, name: (T) -> String) -> [Row] {
      var order: [T] = []
      var german: [T: [String]] = [:]
      var english: [T: [String]] = [:]
      for (phrase, value) in table {
        if german[value] == nil, english[value] == nil { order.append(value) }
        if phrase.english { english[value, default: []].append(phrase.text) } else { german[value, default: []].append(phrase.text) }
      }
      return order.map { Row(id: "\(value(for: $0))", action: name($0), german: german[$0] ?? [], english: english[$0] ?? [], modes: modes) }
    }
    func value<T>(for item: T) -> String { String(describing: item) }
    return [
      Group(id: "structure", title: "Struktur", note: "Normal + Literal · als eigene Äußerung mit Pause davor und danach", rows:
        rows(CommandGrammar.structural + CommandGrammar.structuralIsolatedOnly, modes: "N · L") { $0 == .newLine ? "Neue Zeile ↵" : "Neuer Absatz ¶" }),
      Group(id: "edit", title: "Korrigieren", note: "Normal + Literal · als eigene Äußerung", rows:
        rows(CommandGrammar.edit, modes: "N · L") { Self.editName($0) }),
      Group(id: "punctuation", title: "Satzzeichen", note: "nur Literal · überall im Satz", rows:
        rows(CommandGrammar.punctuation, modes: "L") { "\($0.glyph(language: "de"))  \(Self.punctuationName($0))" }),
      Group(id: "format", title: "Format", note: "Literal · in der Diktierbox auch über die Symbolleiste", rows:
        rows(CommandGrammar.formatIsolated + CommandGrammar.formatInline + CommandGrammar.formatPrefix, modes: "L") { Self.formatName($0) }),
      Group(id: "box", title: "Diktierbox", note: "nur bei offener Box · als eigene Äußerung", rows:
        rows(CommandGrammar.box, modes: "Box") { $0 == .transfer ? "Text einfügen & schließen" : "Buchstabiermodus" }),
    ]
  }

  private func filtered(_ rows: [Row]) -> [Row] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return rows }
    return rows.filter { row in
      row.action.lowercased().contains(query) || (row.german + row.english).contains { $0.lowercased().contains(query) }
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader(title: "Befehle", subtitle: "Was du sagen kannst – und wann es als Befehl zählt", symbol: "command")
        switches
        TextField("Befehl suchen", text: $search)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 280)
        ForEach(groups) { group in
          let rows = filtered(group.rows)
          if !rows.isEmpty {
            Card(title: group.title) {
              Text(group.note).font(.caption).foregroundStyle(.secondary)
              Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                  Text("Aktion").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  Text("Deutsch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  Text("Englisch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Divider().gridCellColumns(3)
                ForEach(rows) { row in
                  GridRow {
                    Text(row.action).fontWeight(.medium).frame(minWidth: 150, alignment: .leading)
                    Text(row.german.map { "„\($0)“" }.joined(separator: ", ")).foregroundStyle(.primary)
                    Text(row.english.joined(separator: ", "))
                      .foregroundStyle(store.hexSettings.englishCommandsEnabled ? .secondary : .tertiary)
                  }
                  .font(.callout)
                }
              }
            }
          }
        }
      }
      .padding(LocalASRDesign.pagePadding)
    }
  }

  private var switches: some View {
    Card(title: "Verhalten", systemImage: "slider.horizontal.3") {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Befehlspause")
          Slider(
            value: Binding(
              get: { store.hexSettings.spokenCommandPauseSeconds },
              set: { store.send(.setSpokenCommandPause($0)) }
            ),
            in: 0.25 ... 1.2,
            step: 0.05
          )
          Text("\(Int((store.hexSettings.spokenCommandPauseSeconds * 1_000).rounded())) ms")
            .monospacedDigit()
            .frame(width: 64, alignment: .trailing)
        }
        Text("So lange musst du vor und nach „neuer Absatz“, „streich das“ usw. schweigen, damit es als Befehl gilt. Mitten im Satz bleibt es normaler Text.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Divider()
      toggle("Formatierung für KI-Agenten & Code (Normal)", \.agentFormattingEnabled,
             "Dateinamen (ContentView Punkt swift), camelCase/snake_case, Backticks, /Befehle.")
      toggle("Zahlen und Einheiten formatieren", \.numberFormattingEnabled,
             "„zwei Komma fünf Milligramm“ → 2,5 mg, Datumsangaben, Prozent.")
      toggle("Englische Befehle erkennen", \.englishCommandsEnabled,
             "Zusätzlich „new paragraph“, „period“, „scratch that“ …")
    }
  }

  private func toggle(_ title: String, _ keyPath: WritableKeyPath<HexSettings, Bool>, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(title, isOn: Binding(
        get: { store.hexSettings[keyPath: keyPath] },
        set: { value in store.$hexSettings.withLock { $0[keyPath: keyPath] = value } }
      ))
      .toggleStyle(.switch)
      Text(caption).font(.caption).foregroundStyle(.secondary)
    }
  }

  static func editName(_ command: EditCommand) -> String {
    switch command {
    case .deleteLastUtterance: "Letzte Äußerung streichen"
    case .deleteLastSentence: "Letzten Satz löschen"
    case .deleteLastWord: "Letztes Wort löschen"
    case .undo: "Rückgängig"
    case .clearAll: "Alles löschen"
    }
  }

  static func formatName(_ command: FormatCommand) -> String {
    switch command {
    case .capitalizeNext: "Nächstes Wort groß"
    case .allCapsNext: "Nächstes Wort in GROSSBUCHSTABEN"
    case .lowercaseNext: "Nächstes Wort klein"
    case .bullet: "Aufzählungspunkt"
    case .numberedItem: "Nummerierter Punkt"
    case .heading: "Überschrift"
    case .boldStart: "Fett an"
    case .boldEnd: "Fett aus"
    case .italicStart: "Kursiv an"
    case .italicEnd: "Kursiv aus"
    }
  }

  static func punctuationName(_ mark: PunctuationMark) -> String {
    switch mark {
    case .period: "Punkt"
    case .comma: "Komma"
    case .colon: "Doppelpunkt"
    case .semicolon: "Semikolon"
    case .question: "Fragezeichen"
    case .exclamation: "Ausrufezeichen"
    case .hyphen: "Bindestrich"
    case .dash: "Gedankenstrich"
    case .slash: "Schrägstrich"
    case .backslash: "Backslash"
    case .underscore: "Unterstrich"
    case .at: "At-Zeichen"
    case .ampersand: "Und-Zeichen"
    case .percent: "Prozentzeichen"
    case .parenOpen: "Klammer auf"
    case .parenClose: "Klammer zu"
    case .bracketOpen: "Eckige Klammer auf"
    case .bracketClose: "Eckige Klammer zu"
    case .braceOpen: "Geschweifte Klammer auf"
    case .braceClose: "Geschweifte Klammer zu"
    case .quoteOpen: "Anführungszeichen auf"
    case .quoteClose: "Anführungszeichen zu"
    case .singleQuoteOpen: "Einfaches Anführungszeichen auf"
    case .singleQuoteClose: "Einfaches Anführungszeichen zu"
    case .ellipsis: "Auslassungspunkte"
    case .space: "Leerzeichen"
    }
  }
}
