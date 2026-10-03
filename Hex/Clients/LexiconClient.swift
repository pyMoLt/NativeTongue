import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let lexiconLogger = HexLog.settings

/// Parameters that decide which lexicon parts are active for one request.
struct LexiconContext: Equatable, Sendable {
  var mode: DictationMode
  var language: String
  var profile: ASRProfile
  var activePacks: [String]
  var autoReplacePackTermsInLiteral: Bool
}

/// User lexicon, imported word packs, automatic correction and suggestions (plan 5.7).
/// Word packs live only in Application Support; nothing is downloaded here.
@DependencyClient
struct LexiconClient {
  /// Corrector for a finished dictation; `nil` when the lexicon is empty.
  var corrector: @Sendable (LexiconContext) async -> LexiconCorrector?
  var suggestions: @Sendable (_ text: String, _ context: LexiconContext) async -> [Suggestion] = { _, _ in [] }
  /// Terms used for model biasing (Qwen/Whisper context), user entries of the profile first.
  var biasTerms: @Sendable (_ profile: ASRProfile) async -> [String] = { _ in [] }
  var userLexicon: @Sendable () async -> UserLexicon = { UserLexicon() }
  /// Exact aliases for live typing, from active packs and eligible user entries.
  var streamingAliases: @Sendable (_ packs: [String], _ profile: ASRProfile) async -> [String: String] = { _, _ in [:] }
  var saveUserLexicon: @Sendable (UserLexicon) async throws -> Void
  /// Adds entries; an existing term (case-insensitive) gets the new aliases merged.
  var addUserEntries: @Sendable ([LexiconEntry]) async throws -> Void
  var installedPacks: @Sendable () async -> [LexiconPackInfo] = { [] }
  var importPack: @Sendable (URL) async throws -> LexiconPackInfo
  var removePack: @Sendable (String) async throws -> Void
  /// One-time migration of V1 vocabulary fields and word remappings.
  var migrate: @Sendable (HexSettings) async throws -> Void
  /// Builds the pack index in the background so the first dictation is fast.
  var warmUp: @Sendable (_ activePacks: [String]) async -> Void
}

extension LexiconClient: DependencyKey {
  static var liveValue: Self {
    let service = LexiconService()
    // Release the large pack index together with the speech model after the
    // idle time (audit A13: ~130 MB); it is rebuilt when dictation starts.
    NotificationCenter.default.addObserver(forName: .speechModelIdleUnloaded, object: nil, queue: nil) { _ in
      Task { await service.releaseIndexes() }
    }
    return Self(
      corrector: { await service.corrector($0) },
      suggestions: { await service.suggestions(for: $0, context: $1) },
      biasTerms: { await service.biasTerms(profile: $0) },
      userLexicon: { await service.userLexicon() },
      streamingAliases: { await service.streamingAliases(activePacks: $0, profile: $1) },
      saveUserLexicon: { try await service.saveUserLexicon($0) },
      addUserEntries: { try await service.addUserEntries($0) },
      installedPacks: { await service.installedPacks() },
      importPack: { try await service.importPack(from: $0) },
      removePack: { try await service.removePack(id: $0) },
      migrate: { try await service.migrate($0) },
      warmUp: { await service.warmUp(activePacks: $0) }
    )
  }

  static let testValue = Self(
    corrector: { _ in nil },
    suggestions: { _, _ in [] },
    biasTerms: { _ in [] },
    userLexicon: { UserLexicon() },
    streamingAliases: { _, _ in [:] },
    saveUserLexicon: { _ in },
    addUserEntries: { _ in },
    installedPacks: { [] },
    importPack: { _ in throw CancellationError() },
    removePack: { _ in },
    migrate: { _ in },
    warmUp: { _ in }
  )
}

extension DependencyValues {
  var lexicon: LexiconClient {
    get { self[LexiconClient.self] }
    set { self[LexiconClient.self] = newValue }
  }
}

/// Owns the lexicon files and the (expensive) pack index. The pack index is
/// rebuilt only when the set of active packs changes; the user index is small
/// and rebuilt on every user edit.
actor LexiconService {
  private let store: LexiconStore?
  private var user: UserLexicon?
  private var userIndex: LexiconIndex?
  private var packIndex: (ids: [String], index: LexiconIndex)?
  private var packIndexTask: (ids: [String], task: Task<LexiconIndex, Never>)?
  private var streamingPackAliases: (ids: [String], aliases: [String: String])?

  init(store: LexiconStore? = try? .defaultStore()) {
    self.store = store
  }

  // MARK: User lexicon

  func userLexicon() -> UserLexicon {
    if let user { return user }
    do {
      let loaded = try store?.loadUser() ?? UserLexicon()
      user = loaded
      return loaded
    } catch {
      // Do not cache the failure: the next call retries (e.g. after unlocking).
      lexiconLogger.error("Could not read user lexicon: \(error.localizedDescription, privacy: .private)")
      return UserLexicon()
    }
  }

  func saveUserLexicon(_ lexicon: UserLexicon) throws {
    try store?.saveUser(lexicon)
    user = lexicon
    userIndex = nil
  }

  func addUserEntries(_ entries: [LexiconEntry]) throws {
    var lexicon = userLexicon()
    for entry in entries {
      let key = LexiconIndex.normalize(entry.term)
      if let index = lexicon.entries.firstIndex(where: { LexiconIndex.normalize($0.term) == key }) {
        for alias in entry.aliases where !lexicon.entries[index].aliases.contains(where: { $0.lowercased() == alias.lowercased() }) {
          lexicon.entries[index].aliases.append(alias)
        }
      } else {
        lexicon.entries.append(entry)
      }
    }
    try saveUserLexicon(lexicon)
  }

  func migrate(_ settings: HexSettings) throws {
    let migrated = LexiconMigration.migrate(settings, into: userLexicon())
    if migrated != userLexicon() { try saveUserLexicon(migrated) }
    lexiconLogger.notice("Lexicon migration finished with \(migrated.entries.count) user entries")
  }

  func biasTerms(profile: ASRProfile) -> [String] {
    Array(userLexicon().entries
      .filter { $0.profile == nil || $0.profile == profile }
      .map(\.term)
      .prefix(50))
  }

  func streamingAliases(activePacks: [String], profile: ASRProfile) async -> [String: String] {
    let installed = Set(installedPacks().map(\.id))
    let ids = activePacks.filter(installed.contains).sorted()
    var aliases: [String: String]
    if let cache = streamingPackAliases, cache.ids == ids {
      aliases = cache.aliases
    } else {
      aliases = [:]
      // Exact aliases need no 200k-entry phonetic index. Decode the active
      // packs once, retain only their small alias map for later sessions.
      if let store {
        for id in ids {
          do {
            let pack = try store.loadPack(id: id)
            for entry in pack.entries {
              for alias in entry.aliases {
                aliases[LexiconIndex.normalize(alias)] = entry.term
              }
            }
          } catch {
            lexiconLogger.error("Could not load streaming word pack: \(error.localizedDescription, privacy: .private)")
          }
        }
      }
      streamingPackAliases = (ids, aliases)
    }
    // Personal variants take precedence and obey the user's auto-replace flag.
    for entry in userLexicon().entries where entry.autoReplace && (entry.profile == nil || entry.profile == profile) {
      for alias in entry.aliases {
        aliases[LexiconIndex.normalize(alias)] = entry.term
      }
    }
    return aliases
  }

  // MARK: Packs

  func installedPacks() -> [LexiconPackInfo] {
    store?.installedPacks() ?? []
  }

  func importPack(from url: URL) throws -> LexiconPackInfo {
    guard let store else { throw CocoaError(.fileNoSuchFile) }
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let info = try store.importPack(from: url)
    packIndex = nil
    packIndexTask = nil
    streamingPackAliases = nil
    return info
  }

  func removePack(id: String) throws {
    try store?.removePack(id: id)
    packIndex = nil
    packIndexTask = nil
    streamingPackAliases = nil
  }

  func warmUp(activePacks: [String]) async {
    _ = await index(for: activePacks)
  }

  func releaseIndexes() {
    guard packIndex != nil || userIndex != nil else { return }
    packIndex = nil
    packIndexTask = nil
    userIndex = nil
    lexiconLogger.notice("Released lexicon index after idle time")
  }

  // MARK: Correction and suggestions

  func corrector(_ context: LexiconContext) async -> LexiconCorrector? {
    let indexes = await indexes(activePacks: context.activePacks)
    guard !indexes.isEmpty else { return nil }
    return LexiconCorrector(
      indexes: indexes,
      wordChecker: SystemWordChecker.shared,
      options: .init(
        mode: context.mode,
        language: context.language,
        profile: context.profile,
        autoReplacePackTermsInLiteral: context.autoReplacePackTermsInLiteral
      )
    )
  }

  func suggestions(for text: String, context: LexiconContext) async -> [Suggestion] {
    let indexes = await indexes(activePacks: context.activePacks)
    guard !indexes.isEmpty else { return [] }
    return SuggestionRanker(indexes: indexes).suggestions(for: text, language: context.language, profile: context.profile)
  }

  private func indexes(activePacks: [String]) async -> [LexiconIndex] {
    var result: [LexiconIndex] = []
    if userIndex == nil, !userLexicon().entries.isEmpty {
      userIndex = LexiconIndex(userEntries: userLexicon().entries)
    }
    if let userIndex { result.append(userIndex) }
    if let packs = await index(for: activePacks) { result.append(packs) }
    return result
  }

  private func index(for ids: [String]) async -> LexiconIndex? {
    let ids = ids.sorted()
    let installed = Set(installedPacks().map(\.id))
    let available = ids.filter(installed.contains)
    guard !available.isEmpty, let store else { return nil }
    if let packIndex, packIndex.ids == available { return packIndex.index }
    if let packIndexTask, packIndexTask.ids == available { return await packIndexTask.task.value }
    let task = Task.detached(priority: .utility) { () -> LexiconIndex in
      let start = Date()
      let packs = available.compactMap { id -> LexiconPack? in
        do { return try store.loadPack(id: id) } catch {
          lexiconLogger.error("Could not load word pack: \(error.localizedDescription, privacy: .private)")
          return nil
        }
      }
      let index = LexiconIndex(packs: packs)
      lexiconLogger.notice("Built lexicon index: \(index.count) entries in \(Date().timeIntervalSince(start), format: .fixed(precision: 2)) s")
      return index
    }
    packIndexTask = (available, task)
    let index = await task.value
    if packIndexTask?.ids == available {
      packIndex = (available, index)
      packIndexTask = nil
    }
    return index
  }
}
