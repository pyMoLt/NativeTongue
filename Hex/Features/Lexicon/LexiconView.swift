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
    .alert("Wortschatz", isPresented: Binding(
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
        Text("Eigene Begriffe").font(.headline)
        Text("\(store.userEntries.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        TextField("Suchen", text: $store.searchText)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 220)
      }
      Text("Richtige Schreibweise und bekannte Fehlerkennungen. Varianten werden immer ersetzt; ähnlich klingende Wörter nur, wenn „Auto“ an ist.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Table(store.filteredEntries, selection: $store.selection) {
        TableColumn("Schreibweise") { entry in
          Text(entry.term).fontWeight(.medium)
        }
        TableColumn("Varianten (werden ersetzt)") { entry in
          Text(entry.aliases.joined(separator: ", "))
            .foregroundStyle(.secondary)
        }
        TableColumn("Profil") { entry in
          Text(entry.profile.map(Self.profileName) ?? "Alle")
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
          .help("Ähnlich klingende Fehlerkennungen automatisch ersetzen")
        }
        .width(44)
      }
      .frame(minHeight: 180, maxHeight: 320)
      .onDeleteCommand { store.send(.deleteSelected) }

      HStack(spacing: 8) {
        TextField("Neuer Begriff, z. B. ST-Hebungsinfarkt", text: $store.draftTerm)
          .textFieldStyle(.roundedBorder)
          .onSubmit { store.send(.addDraft) }
        TextField("Varianten, mit Komma getrennt", text: $store.draftAliases)
          .textFieldStyle(.roundedBorder)
          .onSubmit { store.send(.addDraft) }
        Picker("", selection: $store.draftProfile) {
          Text("Alle Profile").tag(ASRProfile?.none)
          ForEach(ASRProfile.allCases, id: \.self) { profile in
            Text(Self.profileName(profile)).tag(Optional(profile))
          }
        }
        .labelsHidden()
        .frame(width: 130)
        Button {
          store.send(.addDraft)
        } label: {
          Label("Hinzufügen", systemImage: "plus")
        }
        .disabled(store.draftTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        Button(role: .destructive) {
          store.send(.deleteSelected)
        } label: {
          Label("Entfernen", systemImage: "minus")
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
        Text("Wortpakete").font(.headline)
        Spacer()
        if store.isImporting { ProgressView().controlSize(.small) }
        Button {
          store.send(.binding(.set(\.isImporterPresented, true)))
        } label: {
          Label("Wortpaket hinzufügen…", systemImage: "square.and.arrow.down")
        }
        .controlSize(.small)
      }
      Text("Fachwortlisten für Vorschläge und automatische Korrektur (Diagnosen, Wirkstoffe, Anatomie, Technik). Sie bleiben lokal auf diesem Mac und werden nie an das Sprachmodell geschickt.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if store.packs.isEmpty {
        Text("Noch keine Wortpakete installiert. Importiere die JSON-Dateien aus „06-wortlisten/packs“.")
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
                  Text("\(pack.entryCount.formatted()) Begriffe · \(ByteCountFormatter.string(fromByteCount: Int64(pack.fileBytes), countStyle: .file))\(pack.license.map { " · \($0)" } ?? "")")
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
      Text("Korrektur").font(.headline)
      Toggle("Fachwörter im Literal-Modus automatisch ersetzen", isOn: Binding(
        get: { store.hexSettings.autoReplaceTermsLiteral },
        set: { value in store.$hexSettings.withLock { $0.autoReplaceTermsLiteral = value } }
      ))
      Text("Ersetzt nur Wörter, die kein normales deutsches oder englisches Wort sind, bei sehr hoher Ähnlichkeit und nie zwischen bekannten Verwechslungspaaren (z. B. Nervus ↔ Nävus). Alle Ersetzungen sind in der Diktierbox markiert.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  static func profileName(_ profile: ASRProfile) -> String {
    switch profile {
    case .general: "Allgemein"
    case .medical: "Medizin"
    case .technical: "Technik"
    }
  }

  static func packName(_ id: String) -> String {
    switch id {
    case "medical-de": "Medizin Deutsch"
    case "medical-en": "Medizin Englisch"
    case "anatomy-la": "Anatomie Latein"
    case "technical": "Technik & Software"
    default: id
    }
  }
}
