import ComposableArchitecture
import HexCore
import SwiftUI

/// Main window (plan 5.10): sidebar with glass background, calm detail pages.
struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  private struct Item: Identifiable {
    let tab: AppFeature.ActiveTab
    let title: String
    let symbol: String
    var id: AppFeature.ActiveTab { tab }
  }

  private let primary: [Item] = [
    Item(tab: .dictation, title: "Dictation", symbol: "mic.fill"),
    Item(tab: .models, title: "Models", symbol: "cpu"),
    Item(tab: .vocabulary, title: "Vocabulary", symbol: "character.book.closed"),
    Item(tab: .commands, title: "Commands", symbol: "command"),
    Item(tab: .dictationBox, title: "Dictation Box", symbol: "text.below.photo"),
  ]
  private let secondary: [Item] = [
    Item(tab: .audioImport, title: "Files", symbol: "doc.badge.waveform"),
    Item(tab: .history, title: "History", symbol: "clock"),
  ]
  private let footer: [Item] = [
    Item(tab: .settings, title: "Settings", symbol: "gearshape"),
    Item(tab: .remappings, title: "Post-processing", symbol: "text.badge.minus"),
    Item(tab: .about, title: "About", symbol: "info.circle"),
  ]

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: Binding(get: { store.activeTab }, set: { if let tab = $0 { store.send(.setActiveTab(tab)) } })) {
        Section { rows(primary) } header: { brand }
        Section("Tools") { rows(secondary) }
        Section("App") { rows(footer) }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .sheet(isPresented: Binding(
      get: { store.isOnboardingPresented },
      set: { store.send(.presentOnboarding($0)) }
    )) {
      OnboardingView(store: store)
    }
    .task {
      if !store.hexSettings.hasCompletedV2Onboarding { store.send(.presentOnboarding(true)) }
    }
  }

  private var brand: some View {
    HStack(spacing: 8) {
      Image("MenuBarIdle")
        .renderingMode(.template)
        .foregroundStyle(.tint)
      Text(AppBrand.name).font(.headline)
      Spacer()
      Text(store.hexSettings.dictationMode == .literal ? "¶ Literal" : "Normal")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .capsule)
    }
    .padding(.bottom, 6)
    .textCase(nil)
  }

  private func rows(_ items: [Item]) -> some View {
    ForEach(items) { item in
      Label(item.title, systemImage: item.symbol)
        .tag(item.tab)
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch store.activeTab {
    case .dictation:
      DictationHomeView(store: store)
    case .models:
      ModelsPageView(store: store.scope(state: \.settings.modelDownload, action: \.settings.modelDownload))
    case .vocabulary:
      LexiconView(store: store.scope(state: \.lexicon, action: \.lexicon))
    case .commands:
      CommandsPageView(store: store.scope(state: \.settings, action: \.settings))
    case .dictationBox:
      BoxSettingsPageView(store: store.scope(state: \.settings, action: \.settings))
    case .audioImport:
      AudioImportView(store: store.scope(state: \.audioImport, action: \.audioImport))
    case .history:
      HistoryView(store: store.scope(state: \.history, action: \.history))
    case .settings:
      SettingsView(
        store: store.scope(state: \.settings, action: \.settings),
        microphonePermission: store.microphonePermission,
        accessibilityPermission: store.accessibilityPermission,
        inputMonitoringPermission: store.inputMonitoringPermission
      )
    case .remappings:
      WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
    case .about:
      AboutView(store: store.scope(state: \.settings, action: \.settings))
    }
  }
}
