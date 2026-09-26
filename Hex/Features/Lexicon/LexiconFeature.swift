import ComposableArchitecture
import Foundation
import HexCore

/// „Wortschatz“: user lexicon entries and imported word packs (plan 5.7 / 5.10).
@Reducer
struct LexiconFeature {
  @ObservableState
  struct State: Equatable {
    var userEntries: [LexiconEntry] = []
    var packs: [LexiconPackInfo] = []
    var searchText = ""
    var selection: Set<LexiconEntry.ID> = []
    var draftTerm = ""
    var draftAliases = ""
    var draftProfile: ASRProfile?
    var isImporterPresented = false
    var isImporting = false
    var errorMessage: String?
    @Shared(.hexSettings) var hexSettings: HexSettings

    var filteredEntries: [LexiconEntry] {
      let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
      guard !query.isEmpty else { return userEntries }
      return userEntries.filter { entry in
        entry.term.lowercased().contains(query) || entry.aliases.contains { $0.lowercased().contains(query) }
      }
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case loaded(UserLexicon, [LexiconPackInfo])
    case addDraft
    case deleteSelected
    case updateEntry(LexiconEntry.ID, LexiconEntry)
    case setPackActive(String, Bool)
    case importPacks([URL])
    case importFinished(String?)
    case removePack(String)
    case failed(String)
  }

  @Dependency(\.lexicon) var lexicon

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        return reload()

      case let .loaded(user, packs):
        state.userEntries = user.entries
        state.packs = packs
        let installed = Set(packs.map(\.id))
        state.$hexSettings.withLock { $0.activeLexiconPacks.removeAll { !installed.contains($0) } }
        return .none

      case .addDraft:
        let term = state.draftTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .none }
        let aliases = LexiconMigration.terms(in: state.draftAliases)
        let entry = LexiconEntry(
          term: term,
          lang: state.hexSettings.outputLanguage == "en" ? "en" : "de",
          category: "user",
          aliases: aliases,
          caseSensitive: true,
          autoReplace: true,
          profile: state.draftProfile
        )
        state.draftTerm = ""
        state.draftAliases = ""
        return save { try await lexicon.addUserEntries([entry]) }

      case .deleteSelected:
        let selection = state.selection
        guard !selection.isEmpty else { return .none }
        state.userEntries.removeAll { selection.contains($0.id) }
        state.selection = []
        let lexiconValue = UserLexicon(entries: state.userEntries)
        return save { try await lexicon.saveUserLexicon(lexiconValue) }

      case let .updateEntry(id, entry):
        guard let index = state.userEntries.firstIndex(where: { $0.id == id }) else { return .none }
        state.userEntries[index] = entry
        let lexiconValue = UserLexicon(entries: state.userEntries)
        return save { try await lexicon.saveUserLexicon(lexiconValue) }

      case let .setPackActive(id, active):
        state.$hexSettings.withLock { settings in
          settings.activeLexiconPacks.removeAll { $0 == id }
          if active { settings.activeLexiconPacks.append(id) }
        }
        let packs = state.hexSettings.activeLexiconPacks
        return .run { _ in await lexicon.warmUp(packs) }

      case let .importPacks(urls):
        state.isImporting = true
        state.errorMessage = nil
        return .run { send in
          var imported: [String] = []
          for url in urls {
            do {
              imported.append(try await lexicon.importPack(url).id)
            } catch {
              await send(.failed("„\(url.lastPathComponent)“ ist kein gültiges Wortpaket."))
            }
          }
          await send(.importFinished(imported.first))
          for id in imported { await send(.setPackActive(id, true)) }
        }

      case .importFinished:
        state.isImporting = false
        return reload()

      case let .removePack(id):
        state.$hexSettings.withLock { $0.activeLexiconPacks.removeAll { $0 == id } }
        return save { try await lexicon.removePack(id) }

      case let .failed(message):
        state.isImporting = false
        state.errorMessage = message
        return .none
      }
    }
  }

  private func reload() -> Effect<Action> {
    .run { send in
      await send(.loaded(await lexicon.userLexicon(), await lexicon.installedPacks()))
    }
  }

  private func save(_ operation: @escaping @Sendable () async throws -> Void) -> Effect<Action> {
    .run { send in
      do {
        try await operation()
        await send(.loaded(await lexicon.userLexicon(), await lexicon.installedPacks()))
      } catch {
        await send(.failed("Speichern fehlgeschlagen: \(error.localizedDescription)"))
      }
    }
  }
}
