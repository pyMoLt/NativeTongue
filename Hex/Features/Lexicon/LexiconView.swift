import ComposableArchitecture
import HexCore
import SwiftUI
import UniformTypeIdentifiers

struct LexiconView: View {
  @Bindable var store: StoreOf<LexiconFeature>

  var body: some View {
    FlowPage("Vocabulary", subtitle: "Your terms and word packs correct spelling and misrecognitions", symbol: "character.book.closed") {
      userLexiconSection
      snippetsSection
      learnedSection
      packsSection
      behaviourSection
    }
    .task { store.send(.task) }
    .fileImporter(
      isPresented: $store.isImporterPresented,
      allowedContentTypes: [.json],
      allowsMultipleSelection: true
    ) { result in
      if case let .success(urls) = result { store.send(.importPacks(urls)) }
    }
    .alert("Vocabulary", isPresented: Binding(
      get: { store.errorMessage != nil },
      set: { if !$0 { store.send(.binding(.set(\.errorMessage, nil))) } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(store.errorMessage ?? "")
    }
  }

  // MARK: User lexicon

  private var userLexiconSection: some View {
    FlowGroup("Your terms · \(store.userEntries.count)", footer: "Variants are always replaced; similar-sounding words only when “Auto” is on. Select a row and press ⌫ to remove it.") {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search your terms", text: $store.searchText)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 9)
      .flowPill()

      Table(store.filteredEntries, selection: $store.selection) {
        TableColumn("Spelling") { entry in
          Text(entry.term).fontWeight(.medium)
        }
        TableColumn("Variants (replaced)") { entry in
          Text(entry.aliases.joined(separator: ", "))
            .foregroundStyle(.secondary)
        }
        TableColumn("Profile") { entry in
          Text(entry.profile.map(Self.profileName) ?? "All")
            .foregroundStyle(.secondary)
        }
        .width(90)
        TableColumn("Auto") { entry in
          Toggle("", isOn: Binding(
            get: { entry.autoReplace },
            set: { value in
              var updated = entry
              updated.autoReplace = value
              store.send(.updateEntry(entry.id, updated))
            }
          ))
          .labelsHidden()
          .toggleStyle(.checkbox)
          .help("Automatically replace similar-sounding misrecognitions")
        }
        .width(44)
      }
      .tableStyle(.inset(alternatesRowBackgrounds: false))
      .scrollContentBackground(.hidden)
      .frame(minHeight: 180, maxHeight: 320)
      .padding(8)
      .flowPanel()
      .onDeleteCommand { store.send(.deleteSelected) }

      HStack(spacing: 8) {
        TextField("New term, e.g. SwiftUI", text: $store.draftTerm)
          .flowField()
          .onSubmit { store.send(.addDraft) }
        TextField("Variants, comma-separated", text: $store.draftAliases)
          .flowField()
          .onSubmit { store.send(.addDraft) }
        Picker("", selection: $store.draftProfile) {
          Text("All profiles").tag(ASRProfile?.none)
          ForEach(ASRProfile.allCases, id: \.self) { profile in
            Text(Self.profileName(profile)).tag(Optional(profile))
          }
        }
        .labelsHidden()
        .fixedSize()
        Button {
          store.send(.addDraft)
        } label: {
          Label("Add", systemImage: "plus")
        }
        .buttonStyle(.flowPrimary)
        .disabled(store.draftTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        Button(role: .destructive) {
          store.send(.deleteSelected)
        } label: {
          Label("Remove", systemImage: "minus")
        }
        .buttonStyle(.flow)
        .disabled(store.selection.isEmpty)
      }
    }
  }

  // MARK: Snippets (plan B6)

  private var snippetsSection: some View {
    FlowGroup("Snippets", footer: "Say the trigger as a phrase of its own, with a short pause before and after. {date} and {time} are filled in when the snippet is inserted. Works in Normal, Literal, Streaming and the box.") {
      ForEach(store.snippets) { snippet in
        SnippetEditor(snippet: snippet) { store.send(.updateSnippet($0)) } onDelete: { store.send(.deleteSnippet(snippet.id)) }
      }
      HStack {
        Spacer()
        Button {
          store.send(.addSnippet)
        } label: {
          Label("Add snippet", systemImage: "plus")
        }
        .buttonStyle(.flow)
      }
    }
  }

  // MARK: Learned corrections (plan B8)

  @ViewBuilder
  private var learnedSection: some View {
    if !store.learnedCorrections.isEmpty {
      FlowGroup("Learned from your corrections", footer: "Corrections you made by hand in the dictation box, counted. From \(store.hexSettings.textProcessing.learnCorrectionThreshold) on, NativeTongue asks whether to always replace them.") {
        ForEach(store.learnedCorrections) { item in
          FlowRow("\(item.original) → \(item.replacement)",
                  caption: item.declined ? "\(item.count)× · not offered again" : "\(item.count)×") {
            Button(role: .destructive) {
              store.send(.deleteLearnedCorrection(item.id))
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.flowQuiet)
            .help("Forget this correction")
            .accessibilityLabel("Forget \(item.original) → \(item.replacement)")
          }
        }
        FlowRow("Ask after", caption: "How many identical corrections before NativeTongue offers “Always replace?”") {
          HStack(spacing: 8) {
            Text("\(store.hexSettings.textProcessing.learnCorrectionThreshold)×")
              .monospacedDigit()
            Stepper(
            "Ask after",
            value: Binding(
              get: { store.hexSettings.textProcessing.learnCorrectionThreshold },
              set: { value in store.$hexSettings.withLock { $0.textProcessing.learnCorrectionThreshold = min(max(value, 1), 5) } }
            ),
            in: 1...5
          )
          .labelsHidden()
          }
          .fixedSize()
        }
      }
    }
  }

  // MARK: Packs

  private var packsSection: some View {
    FlowGroup("Word packs", footer: "Domain word lists for suggestions and automatic correction. They stay on this Mac and are never sent to the speech model.") {
      if store.packs.isEmpty {
        FlowBlock {
          FlowEmptyState(symbol: "books.vertical", title: "No word packs yet", message: "Import word pack JSON files to add domain terms.")
        }
      } else {
        ForEach(store.packs) { pack in
          FlowRow(Self.packName(pack.id),
                  caption: "\(pack.entryCount.formatted()) terms · \(ByteCountFormatter.string(fromByteCount: Int64(pack.fileBytes), countStyle: .file))\(pack.license.map { " · \($0)" } ?? "")") {
            HStack(spacing: 10) {
              Button(role: .destructive) {
                store.send(.removePack(pack.id))
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.flowQuiet)
              .help("Remove word pack")
              .accessibilityLabel("Remove word pack \(Self.packName(pack.id))")
              Toggle("", isOn: Binding(
                get: { store.hexSettings.activeLexiconPacks.contains(pack.id) },
                set: { store.send(.setPackActive(pack.id, $0)) }
              ))
              .toggleStyle(.switch)
              .labelsHidden()
              .accessibilityLabel("Use \(Self.packName(pack.id))")
            }
          }
        }
      }
      HStack {
        Spacer()
        if store.isImporting { ProgressView().controlSize(.small) }
        Button {
          store.send(.binding(.set(\.isImporterPresented, true)))
        } label: {
          Label("Add word pack…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.flow)
      }
    }
  }

  private var behaviourSection: some View {
    FlowGroup("Correction") {
      Toggle(isOn: Binding(
        get: { store.hexSettings.autoReplaceTermsLiteral },
        set: { value in store.$hexSettings.withLock { $0.autoReplaceTermsLiteral = value } }
      )) {
        FlowLabel("Automatically correct domain terms in Literal mode",
                  caption: "Only replaces words that are not ordinary German or English words, only at very high similarity, and never between known confusable pairs. Every replacement is underlined in the dictation box.")
      }
    }
  }

  static func profileName(_ profile: ASRProfile) -> String {
    switch profile {
    case .general: "General"
    case .medical: "Medical"
    case .technical: "Technical"
    }
  }

  static func packName(_ id: String) -> String {
    switch id {
    case "medical-de": "Medical (German)"
    case "medical-en": "Medical (English)"
    case "anatomy-la": "Anatomy (Latin)"
    case "technical": "Technology & software"
    default: id
    }
  }
}

/// One snippet: trigger phrase and (multi-line) text, edited in place.
private struct SnippetEditor: View {
  let snippet: TextSnippet
  let onChange: (TextSnippet) -> Void
  let onDelete: () -> Void
  @State private var trigger = ""
  @State private var text = ""

  var body: some View {
    FlowBlock {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "text.badge.plus")
            .foregroundStyle(.tint)
          TextField("Trigger, e.g. my address", text: $trigger)
            .textFieldStyle(.plain)
            .flowFont(.body, weight: .medium)
          if !snippet.isActive {
            Text(trigger.isEmpty ? "No trigger" : "No text yet")
              .flowFont(.caption)
              .foregroundStyle(.secondary)
          }
          Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
          }
          .buttonStyle(.flowQuiet)
          .help("Delete snippet")
          .accessibilityLabel("Delete snippet \(snippet.trigger)")
        }
        TextEditor(text: $text)
          .flowFont(.body)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 54, maxHeight: 120)
          .accessibilityLabel("Text for \(snippet.trigger)")
      }
    }
    .onAppear {
      trigger = snippet.trigger
      text = snippet.text
    }
    .onChange(of: trigger) { _, value in
      guard value != snippet.trigger else { return }
      var updated = snippet
      updated.trigger = value
      onChange(updated)
    }
    .onChange(of: text) { _, value in
      guard value != snippet.text else { return }
      var updated = snippet
      updated.text = value
      onChange(updated)
    }
  }
}
