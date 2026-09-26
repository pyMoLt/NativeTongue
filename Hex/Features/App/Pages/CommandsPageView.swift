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
      Group(id: "structure", title: "Structure", note: "Normal + Literal · as a separate utterance with a pause before and after", rows:
        rows(CommandGrammar.structural + CommandGrammar.structuralIsolatedOnly, modes: "N · L") { $0 == .newLine ? "New line ↵" : "New paragraph ¶" }),
      Group(id: "edit", title: "Editing", note: "Normal + Literal · as a separate utterance", rows:
        rows(CommandGrammar.edit, modes: "N · L") { Self.editName($0) }),
      Group(id: "punctuation", title: "Punctuation", note: "Literal only · anywhere in a sentence", rows:
        rows(CommandGrammar.punctuation, modes: "L") { "\($0.glyph(language: "de"))  \(Self.punctuationName($0))" }),
      Group(id: "format", title: "Format", note: "Literal · also available in the dictation box toolbar", rows:
        rows(CommandGrammar.formatIsolated + CommandGrammar.formatInline + CommandGrammar.formatPrefix, modes: "L") { Self.formatName($0) }),
      Group(id: "box", title: "Dictation Box", note: "only while the box is open · as a separate utterance", rows:
        rows(CommandGrammar.box, modes: "Box") { $0 == .transfer ? "Insert text & close" : "Spelling mode" }),
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
        PageHeader(title: "Commands", subtitle: "What you can say – and when it counts as a command", symbol: "command")
        switches
        TextField("Search commands", text: $search)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 280)
        ForEach(groups) { group in
          let rows = filtered(group.rows)
          if !rows.isEmpty {
            Card(title: group.title) {
              Text(group.note).font(.caption).foregroundStyle(.secondary)
              Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                  Text("Action").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  Text("German").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  Text("English").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
    Card(title: "Behavior", systemImage: "slider.horizontal.3") {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Command pause")
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
        Text("How long you pause before and after “new paragraph”, “scratch that” etc. for it to count as a command. Inside a sentence it stays text.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Divider()
      toggle("Formatting for AI agents & code (Normal)", \.agentFormattingEnabled,
             "File names (“ContentView dot swift”), camelCase/snake_case, backticks, /commands.")
      toggle("Format numbers and units", \.numberFormattingEnabled,
             "“two point five milligrams” → 2.5 mg, dates, percentages.")
      toggle("Recognize English commands", \.englishCommandsEnabled,
             "Also “new paragraph”, “period”, “scratch that” …")
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
    case .deleteLastUtterance: "Delete last utterance"
    case .deleteLastSentence: "Delete last sentence"
    case .deleteLastWord: "Delete last word"
    case .undo: "Undo"
    case .clearAll: "Clear all"
    }
  }

  static func formatName(_ command: FormatCommand) -> String {
    switch command {
    case .capitalizeNext: "Capitalize next word"
    case .allCapsNext: "Next word in ALL CAPS"
    case .lowercaseNext: "Lowercase next word"
    case .bullet: "Bullet point"
    case .numberedItem: "Numbered item"
    case .heading: "Heading"
    case .boldStart: "Bold on"
    case .boldEnd: "Bold off"
    case .italicStart: "Italic on"
    case .italicEnd: "Italic off"
    }
  }

  static func punctuationName(_ mark: PunctuationMark) -> String {
    switch mark {
    case .period: "Period"
    case .comma: "Komma"
    case .colon: "Doppelpunkt"
    case .semicolon: "Semikolon"
    case .question: "Fragezeichen"
    case .exclamation: "Ausrufezeichen"
    case .hyphen: "Bindestrich"
    case .dash: "Gedankenstrich"
    case .slash: "Slash"
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
    case .quoteOpen: "Open quote"
    case .quoteClose: "Close quote"
    case .singleQuoteOpen: "Open single quote"
    case .singleQuoteClose: "Close single quote"
    case .ellipsis: "Auslassungspunkte"
    case .space: "Leerzeichen"
    }
  }
}
