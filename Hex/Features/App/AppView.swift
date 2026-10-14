import ComposableArchitecture
import HexCore
import SwiftUI

/// Main window ("Flow" design, 2.6): colour field over the whole window, a
/// floating glass sidebar with a gliding selection pill, pages on the field.
struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  struct Item: Identifiable {
    let tab: AppFeature.ActiveTab
    let title: String
    let symbol: String
    var id: AppFeature.ActiveTab { tab }
  }

  /// Sidebar sections, ordered by topic (2.6).
  static let sections: [(title: String?, items: [Item])] = [
    ("Dictation", [
      Item(tab: .dictation, title: "Overview", symbol: "mic.fill"),
      Item(tab: .profiles, title: "Profiles", symbol: "person.2.crop.square.stack"),
      Item(tab: .models, title: "Models", symbol: "cpu"),
      Item(tab: .recording, title: "Recording", symbol: "keyboard"),
      Item(tab: .dictationBox, title: "Dictation Box", symbol: "text.below.photo"),
      Item(tab: .streaming, title: "Streaming", symbol: "dot.radiowaves.left.and.right"),
    ]),
    ("Text", [
      Item(tab: .commands, title: "Commands", symbol: "command"),
      Item(tab: .vocabulary, title: "Vocabulary", symbol: "character.book.closed"),
      Item(tab: .remappings, title: "Word Rules", symbol: "text.badge.minus"),
      Item(tab: .postProcessing, title: "AI Post-Processing", symbol: "sparkles"),
    ]),
    ("Library", [
      Item(tab: .files, title: "Files", symbol: "waveform.badge.plus"),
      Item(tab: .history, title: "History", symbol: "clock"),
    ]),
    ("App", [
      Item(tab: .settings, title: "General", symbol: "gearshape"),
      Item(tab: .appearance, title: "Appearance", symbol: "paintpalette"),
      Item(tab: .about, title: "About", symbol: "info.circle"),
    ]),
  ]

  private var variant: Int {
    AppFeature.ActiveTab.allCases.firstIndex(of: store.activeTab) ?? 0
  }

  var body: some View {
    ZStack {
      FlowBackdrop(variant: variant)
      HStack(spacing: 0) {
        FlowSidebar(store: store)
          .padding(10)
        // Pages switch instantly; the selection pill glides and the colour
        // field flows, so the change still feels continuous.
        detail
          .id(store.activeTab)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .modifier(FlowWindowMinimum())
    .flowThemed(store.hexSettings.appearance)
    .sheet(isPresented: Binding(
      get: { store.isOnboardingPresented },
      set: { store.send(.presentOnboarding($0)) }
    )) {
      OnboardingView(store: store)
        .flowThemed(store.hexSettings.appearance)
    }
    .task {
      if !store.hexSettings.hasCompletedV2Onboarding { store.send(.presentOnboarding(true)) }
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch store.activeTab {
    case .dictation:
      DictationHomeView(store: store)
    case .profiles:
      ProfilesPageView(store: store)
    case .recording:
      RecordingPageView(
        store: store.scope(state: \.settings, action: \.settings),
        microphonePermission: store.microphonePermission
      )
    case .models:
      ModelsPageView(
        store: store.scope(state: \.settings.modelDownload, action: \.settings.modelDownload),
        idleUnloadMinutes: Binding(
          get: { store.hexSettings.idleUnloadMinutes },
          set: { store.send(.settings(.setIdleUnloadMinutes($0))) }
        )
      )
    case .vocabulary:
      LexiconView(store: store.scope(state: \.lexicon, action: \.lexicon))
    case .commands:
      CommandsPageView(store: store.scope(state: \.settings, action: \.settings))
    case .dictationBox:
      BoxSettingsPageView(store: store.scope(state: \.settings, action: \.settings))
    case .postProcessing:
      PostProcessingPageView(store: store.scope(state: \.settings, action: \.settings))
    case .streaming:
      StreamingPageView(store: store.scope(state: \.settings, action: \.settings))
    case .files:
      FileTranscriptionView(store: store.scope(state: \.files, action: \.files))
    case .history:
      HistoryView(
        store: store.scope(state: \.history, action: \.history),
        settingsStore: store.scope(state: \.settings, action: \.settings)
      )
    case .settings:
      SettingsView(
        store: store.scope(state: \.settings, action: \.settings),
        microphonePermission: store.microphonePermission,
        accessibilityPermission: store.accessibilityPermission,
        inputMonitoringPermission: store.inputMonitoringPermission
      )
    case .appearance:
      AppearancePageView(store: store.scope(state: \.settings, action: \.settings))
    case .remappings:
      WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
    case .about:
      AboutView(store: store)
    }
  }
}

/// Smallest window content that still shows the sidebar and a page without
/// clipping; it grows with the text size, so the window cannot be narrowed
/// past the content (the hosting view reports it as the window minimum).
private struct FlowWindowMinimum: ViewModifier {
  @Environment(\.flowTheme) private var theme

  func body(content: Content) -> some View {
    let scale = theme.textScale
    let sidebar = FlowSidebar.width(for: scale) + 20
    let page = 2 * FlowMetrics.pagePadding + 560 * max(1, scale)
    content.frame(minWidth: max(880, sidebar + page), minHeight: max(620, 560 * max(1, scale)))
  }
}

/// Floating glass sidebar; the selection is a pill that glides to the
/// clicked entry.
struct FlowSidebar: View {
  static func width(for scale: CGFloat) -> CGFloat { 216 * max(1, scale * 0.95) }

  @Bindable var store: StoreOf<AppFeature>
  @Namespace private var namespace
  @Environment(\.flowTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // A compact brand line, so every entry (down to About) fits without
      // scrolling at the default window size.
      brand
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(AppView.sections, id: \.title) { group in
            if let title = group.title { section(title) }
            rows(group.items)
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
      }
      .scrollIndicators(.never)
    }
    .frame(width: FlowSidebar.width(for: theme.textScale))
    .frame(maxHeight: .infinity, alignment: .top)
    // Only the selection pill glides; the page itself switches instantly.
    .animation(theme.animation(), value: store.activeTab)
    .flowSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
  }

  private var brand: some View {
    HStack(spacing: 7) {
      Image("MenuBarIdle")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 14 * theme.textScale, height: 14 * theme.textScale)
        .foregroundStyle(.white)
        .frame(width: 22 * theme.textScale, height: 22 * theme.textScale)
        .background(LinearGradient(colors: [theme.accent, theme.companion], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 7, style: .continuous))
      Text(AppBrand.name)
        .flowFont(.subheadline, weight: .semibold, design: .rounded)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Spacer(minLength: 0)
    }
    .frame(minHeight: 22)
    .help("\(AppBrand.name) · \(modeLabel) mode")
  }

  private var modeLabel: String {
    switch store.hexSettings.dictationMode {
    case .normal: "Normal"
    case .literal: "Literal"
    case .streaming: "Streaming"
    }
  }

  private func section(_ title: String) -> some View {
    Text(title)
      .flowFont(size: 11, weight: .semibold, design: .rounded)
      .foregroundStyle(.tertiary)
      .padding(.leading, 12)
      .padding(.top, 8)
      .padding(.bottom, 2)
      .accessibilityAddTraits(.isHeader)
  }

  private func rows(_ items: [AppView.Item]) -> some View {
    ForEach(items) { item in
      let selected = store.activeTab == item.tab
      Button {
        store.send(.setActiveTab(item.tab))
      } label: {
        HStack(spacing: 10) {
          Image(systemName: item.symbol)
            .flowFont(size: 13, weight: .medium)
            .foregroundStyle(selected ? theme.accent : .secondary)
            .frame(width: 20 * theme.textScale)
          Text(item.title)
            .flowFont(size: 13, weight: selected ? .semibold : .regular)
            .foregroundStyle(selected ? .primary : .secondary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 27 * theme.textScale)
        .background {
          if selected {
            Capsule()
              .fill(theme.accent.opacity(0.16))
              .matchedGeometryEffect(id: "sidebar-selection", in: namespace)
          }
        }
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .focusEffectDisabled()
      .accessibilityAddTraits(selected ? .isSelected : [])
    }
  }
}
