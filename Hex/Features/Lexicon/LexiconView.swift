import ComposableArchitecture
import HexCore
import SwiftUI
import UniformTypeIdentifiers

struct LexiconView: View {
  @Bindable var store: StoreOf<LexiconFeature>

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        userLexiconSection
        packsSection
        behaviourSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)
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
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Your terms").font(.headline)
        Text("\(store.userEntries.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        TextField("Search", text: $store.searchText)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 220)
      }
      Text("Correct spelling and known misrecognitions. Variants are always replaced; similar-sounding words only when “Auto” is on.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Table(store.filteredEntries, selection: $store.selection) {
        TableColumn("Schreibweise") { entry in
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
      .frame(minHeight: 180, maxHeight: 320)
      .onDeleteCommand { store.send(.deleteSelected) }

      HStack(spacing: 8) {
        TextField("Neuer Begriff, z. B. ST-Hebungsinfarkt", text: $store.draftTerm)
          .textFieldStyle(.roundedBorder)
          .onSubmit { store.send(.addDraft) }
        TextField("Variants, comma-separated", text: $store.draftAliases)
          .textFieldStyle(.roundedBorder)
          .onSubmit { store.send(.addDraft) }
        Picker("", selection: $store.draftProfile) {
          Text("All profiles").tag(ASRProfile?.none)
          ForEach(ASRProfile.allCases, id: \.self) { profile in
            Text(Self.profileName(profile)).tag(Optional(profile))
          }
        }
        .labelsHidden()
        .frame(width: 130)
        Button {
          store.send(.addDraft)
        } label: {
          Label("Add", systemImage: "plus")
        }
        .disabled(store.draftTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        Button(role: .destructive) {
          store.send(.deleteSelected)
        } label: {
          Label("Remove", systemImage: "minus")
        }
        .disabled(store.selection.isEmpty)
      }
      .controlSize(.small)
    }
  }

  // MARK: Packs

  private var packsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Word packs").font(.headline)
        Spacer()
        if store.isImporting { ProgressView().controlSize(.small) }
        Button {
          store.send(.binding(.set(\.isImporterPresented, true)))
        } label: {
          Label("Add word pack…", systemImage: "square.and.arrow.down")
        }
        .controlSize(.small)
      }
      Text("Domain word lists for suggestions and automatic correction. They stay on this Mac and are never sent to the speech model.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if store.packs.isEmpty {
        Text("No word packs installed yet. Import word pack JSON files.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        VStack(spacing: 0) {
          ForEach(store.packs) { pack in
            HStack {
              Toggle(isOn: Binding(
                get: { store.hexSettings.activeLexiconPacks.contains(pack.id) },
                set: { store.send(.setPackActive(pack.id, $0)) }
              )) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(Self.packName(pack.id)).fontWeight(.medium)
                  Text("\(pack.entryCount.formatted()) terms · \(ByteCountFormatter.string(fromByteCount: Int64(pack.fileBytes), countStyle: .file))\(pack.license.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .toggleStyle(.switch)
              Spacer()
              Button(role: .destructive) {
                store.send(.removePack(pack.id))
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
              .help("Wortpaket entfernen")
            }
            .padding(.vertical, 8)
            if pack.id != store.packs.last?.id { Divider() }
          }
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
      }
    }
  }

  private var behaviourSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Correction").font(.headline)
      Toggle("Automatically correct domain terms in Literal mode", isOn: Binding(
        get: { store.hexSettings.autoReplaceTermsLiteral },
        set: { value in store.$hexSettings.withLock { $0.autoReplaceTermsLiteral = value } }
      ))
      Text("Only replaces words that are not ordinary German or English words, only at very high similarity, and never between known confusable pairs. Every replacement is underlined in the dictation box.")
        .font(.caption)
        .foregroundStyle(.secondary)
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
    case "anatomy-la": "Anatomie Latein"
    case "technical": "Technology & software"
    default: id
    }
  }
}
