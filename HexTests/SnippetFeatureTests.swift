import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// Plan B6: snippets on the Vocabulary page.
@MainActor
final class SnippetFeatureTests: XCTestCase {
  func testExamplesAreAddedOnceAndSavingKeepsEverything() async {
    let saved = LockIsolated<[UserLexicon]>([])
    let entry = LexiconEntry(term: "Qwen", lang: "en", category: "user", aliases: ["Gwen"], autoReplace: true)
    let store = TestStore(initialState: LexiconFeature.State(hexSettings: Shared(value: HexSettings()))) {
      LexiconFeature()
    } withDependencies: {
      $0.lexicon.userLexicon = { saved.value.last ?? UserLexicon(entries: [entry]) }
      $0.lexicon.installedPacks = { [] }
      $0.lexicon.saveUserLexicon = { value in saved.withValue { $0.append(value) } }
    }
    store.exhaustivity = .off

    await store.send(.loaded(UserLexicon(entries: [entry]), []))
    XCTAssertEqual(store.state.snippets.map(\.trigger), ["meine Adresse", "meine E-Mail", "Grußformel"])
    XCTAssertTrue(store.state.snippetExamplesAdded)
    await store.skipReceivedActions()

    var address = store.state.snippets[0]
    address.text = "Musterweg 1"
    await store.send(.updateSnippet(address))
    await store.send(.deleteSnippet(store.state.snippets[2].id))
    await store.finish()
    await store.skipReceivedActions()

    let last = try? XCTUnwrap(saved.value.last)
    XCTAssertEqual(last?.entries, [entry], "saving snippets keeps the vocabulary entries")
    XCTAssertEqual(last?.snippets.map(\.trigger), ["meine Adresse", "meine E-Mail"])
    XCTAssertEqual(last?.snippets.first?.text, "Musterweg 1")
    XCTAssertEqual(last?.snippetExamplesAdded, true)

    // Loading a lexicon whose examples were already offered adds nothing.
    await store.send(.loaded(UserLexicon(entries: [entry], snippets: [], snippetExamplesAdded: true), []))
    XCTAssertEqual(store.state.snippets, [])
  }
}
