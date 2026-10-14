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
      Group(id: "edit", title: "Editing", note: "Normal + Literal + Streaming · as a separate utterance · in the box, on your own streamed text, and right after inserting into another app (same text field only)", rows:
        rows((CommandGrammar.edit + CommandGrammar.parameterizedEditExamples).map { ($0.0, Self.editName($0.1)) }, modes: "N · L · S") { $0 }),
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
    FlowPage("Commands", subtitle: "What you can say – and when it counts as a command", symbol: "command") {
      switches
      FlowGroup("Reference") {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Search commands", text: $search)
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .flowPill()
      }
      ForEach(groups) { group in
        let rows = filtered(group.rows)
        if !rows.isEmpty {
          FlowGroup(group.title, footer: group.note) {
            FlowBlock {
              Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                  Text("Action").flowFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                  Text("German").flowFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                  Text("English").flowFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                  GridRow {
                    Text(row.action).fontWeight(.medium).frame(minWidth: 150, alignment: .leading)
                    Text(row.german.map { "„\($0)“" }.joined(separator: ", ")).foregroundStyle(.primary)
                    Text(row.english.joined(separator: ", "))
                      .foregroundStyle(store.hexSettings.englishCommandsEnabled ? .secondary : .tertiary)
                  }
                  .flowFont(.callout)
                }
              }
            }
          }
        }
      }
    }
  }

  private var switches: some View {
    FlowGroup("Behaviour") {
      FlowRow("Command pause", caption: "How long you pause before and after “new paragraph”, “scratch that” etc. for it to count as a command. Inside a sentence it stays text.") {
        HStack(spacing: 10) {
          Slider(
            value: Binding(
              get: { store.hexSettings.spokenCommandPauseSeconds },
              set: { store.send(.setSpokenCommandPause($0)) }
            ),
            in: 0.25 ... 1.2,
            step: 0.05
          )
          .frame(width: 160)
          Text("\(Int((store.hexSettings.spokenCommandPauseSeconds * 1_000).rounded())) ms")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 56, alignment: .trailing)
        }
      }
      toggle("Formatting for AI agents and code (Normal)", \.agentFormattingEnabled,
             "File names (“ContentView dot swift”), camelCase/snake_case, backticks, /commands.")
      toggle("Format numbers and units", \.numberFormattingEnabled,
             "“two point five milligrams” → 2.5 mg, dates, percentages.")
      toggle("Recognise English commands", \.englishCommandsEnabled,
             "Also “new paragraph”, “period”, “scratch that” …")
      toggle("Also understand spoken punctuation in Normal mode", \.textProcessing.spokenPunctuationInNormal,
             "“Komma”, “Doppelpunkt”, “Fragezeichen” become marks in Normal mode too. If the model already set the same mark, you get only one. “a period”, “das Komma” stay words.")
      toggle("Resolve self-corrections", \.textProcessing.resolveSelfCorrections,
             "“on Tuesday, no, on Wednesday” → “on Wednesday”. Only when both sides are the same kind (day, date, time, amount, vocabulary term).")
      toggle("Correction commands while streaming", \.streaming.correctionCommands,
             "“scratch that”, “delete the last three words” remove text NativeTongue typed in this session — never anything else.")
    }
  }

  private func toggle(_ title: String, _ keyPath: WritableKeyPath<HexSettings, Bool>, _ caption: String) -> some View {
    Toggle(isOn: Binding(
      get: { store.hexSettings[keyPath: keyPath] },
      set: { value in store.$hexSettings.withLock { $0[keyPath: keyPath] = value } }
    )) {
      FlowLabel(title, caption: caption)
    }
  }

  static func editName(_ command: EditCommand) -> String {
    switch command {
    case .deleteLastUtterance: "Delete last utterance"
    case .deleteLastSentence: "Delete last sentence"
    case .deleteLastWord: "Delete last word"
    case .deleteLastWords: "Delete last N words (2–10)"
    case .replace: "Replace X with Y (last occurrence)"
    case .undo: "Undo"
    case .clearAll: "Clear all / start over"
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
    case .comma: "Comma"
    case .colon: "Colon"
    case .semicolon: "Semicolon"
    case .question: "Question mark"
    case .exclamation: "Exclamation mark"
    case .hyphen: "Hyphen"
    case .dash: "Dash"
    case .slash: "Slash"
    case .backslash: "Backslash"
    case .underscore: "Underscore"
    case .at: "At sign"
    case .ampersand: "Ampersand"
    case .percent: "Percent sign"
    case .parenOpen: "Open parenthesis"
    case .parenClose: "Close parenthesis"
    case .bracketOpen: "Open bracket"
    case .bracketClose: "Close bracket"
    case .braceOpen: "Open brace"
    case .braceClose: "Close brace"
    case .quoteOpen: "Open quote"
    case .quoteClose: "Close quote"
    case .singleQuoteOpen: "Open single quote"
    case .singleQuoteClose: "Close single quote"
    case .ellipsis: "Ellipsis"
    case .space: "Space"
    }
  }

}
