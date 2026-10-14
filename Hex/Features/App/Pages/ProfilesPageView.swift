import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI
import UniformTypeIdentifiers

/// Profiles (2.6, C2): settings bundles for kinds of work, chosen by the app
/// you dictate into.
struct ProfilesPageView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var editing: DictationProfile?

  private var profiles: ProfileSettings { store.hexSettings.profiles }

  var body: some View {
    FlowPage("Profiles", subtitle: "Mode, vocabulary and AI style for each kind of work – picked by the app you dictate into", symbol: "person.2.crop.square.stack") {
      FlowGroup("Choosing a profile", footer: profiles.switchByApp
        ? "Dictating into an app listed in a profile uses that profile; every other app uses the profile chosen above."
        : "Every dictation uses the profile chosen above.") {
        Toggle(isOn: Binding(
          get: { profiles.switchByApp },
          set: { value in store.$hexSettings.withLock { $0.profiles.switchByApp = value } }
        )) {
          FlowLabel("Switch profile by app")
        }
        Picker("Profile", selection: Binding(
          get: { profiles.manualProfileID },
          set: { value in store.$hexSettings.withLock { $0.profiles.manualProfileID = value } }
        )) {
          ForEach(profiles.profiles) { profile in
            Label(profile.name, systemImage: profile.symbol).tag(profile.id)
          }
        }
        .flowRow(profiles.switchByApp ? "Profile for all other apps" : "Profile")
      }

      FlowGroup("Profiles") {
        ForEach(profiles.profiles) { profile in
          FlowRow(profile.name, caption: summary(profile), systemImage: profile.symbol) {
            HStack(spacing: 8) {
              if profile.id == profiles.manualProfileID { Badge(text: "Default", style: .accent) }
              Button("Edit") { editing = profile }
                .buttonStyle(.flowCompact)
            }
          }
        }
        HStack {
          Spacer()
          Button {
            editing = DictationProfile(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: "New profile", symbol: "star")
          } label: {
            Label("New profile", systemImage: "plus")
          }
          .buttonStyle(.flow)
        }
      }
    }
    .sheet(item: $editing) { profile in
      ProfileEditor(
        profile: profile,
        isNew: !profiles.profiles.contains { $0.id == profile.id },
        styles: store.hexSettings.postProcessing.allStyles,
        packs: store.lexicon.packs.map { ($0.id, LexiconView.packName($0.id)) },
        onSave: { saved in store.$hexSettings.withLock { $0.profiles.save(saved) } },
        onRestore: { store.$hexSettings.withLock { $0.profiles.restore(profile.id) } },
        onDelete: { store.$hexSettings.withLock { $0.profiles.delete(profile.id) } }
      )
      .flowThemed(store.hexSettings.appearance)
    }
  }

  private func summary(_ profile: DictationProfile) -> String {
    var parts: [String] = [profile.domain.displayName]
    if let mode = profile.mode { parts.append(mode.title) }
    if let style = profile.aiStyleID { parts.append("AI: " + store.hexSettings.postProcessing.style(id: style).name) }
    if profile.aiAutomatic == false { parts.append("AI off") }
    let apps = profile.apps.map(\.name)
    parts.append(apps.isEmpty ? "no apps" : apps.prefix(3).joined(separator: ", ") + (apps.count > 3 ? " +\(apps.count - 3)" : ""))
    return parts.joined(separator: " · ")
  }
}

extension DictationMode {
  var title: String {
    switch self {
    case .normal: "Normal"
    case .literal: "Literal"
    case .streaming: "Streaming"
    }
  }
}

/// Edits a profile. Every setting can keep the global value ("Global").
private struct ProfileEditor: View {
  @State var profile: DictationProfile
  let isNew: Bool
  let styles: [AIStyle]
  let packs: [(id: String, name: String)]
  let onSave: (DictationProfile) -> Void
  let onRestore: () -> Void
  let onDelete: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var confirmDelete = false

  private static let symbols = [
    "person.crop.circle", "envelope", "chevron.left.forwardslash.chevron.right", "cross.case", "doc.text",
    "graduationcap", "briefcase", "bubble.left.and.bubble.right", "book", "star",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PageHeader(title: isNew ? "New profile" : profile.name, subtitle: "“Global” keeps the setting from the other pages", symbol: profile.symbol)
      ScrollView {
        VStack(alignment: .leading, spacing: FlowMetrics.groupSpacing) {
          FlowGroup("Profile") {
            FlowRow("Name") {
              TextField("Name", text: $profile.name)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 220)
            }
            FlowRow("Symbol") {
              HStack(spacing: 4) {
                ForEach(Self.symbols, id: \.self) { symbol in
                  Button { profile.symbol = symbol } label: {
                    Image(systemName: symbol)
                      .frame(width: 24, height: 24)
                      .foregroundStyle(profile.symbol == symbol ? Color.white : Color.primary)
                      .background(profile.symbol == symbol ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), in: Circle())
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(symbol)
                }
              }
            }
          }

          FlowGroup("Dictation") {
            FlowSegmented(selection: $profile.domain, options: ASRProfile.allCases.map { FlowOption($0, $0.displayName) }, compact: true)
              .flowRow("Vocabulary domain", caption: "Your terms for this domain and the model you chose for it.")
            Picker("Mode", selection: $profile.mode) {
              Text("Global").tag(DictationMode?.none)
              ForEach(DictationMode.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            .flowRow("Mode")
            Picker("Word packs", selection: packSelection) {
              Text("Global").tag("global")
              Text("None").tag("none")
              ForEach(packs, id: \.id) { pack in Text(pack.name).tag(pack.id) }
              if packs.count > 1 { Text("All installed").tag("all") }
            }
            .flowRow("Word packs")
            triState("Spoken punctuation in Normal", $profile.spokenPunctuationInNormal)
            triState("Code formatting", $profile.codeFormatting)
          }

          FlowGroup("AI") {
            triState("Automatic AI step", $profile.aiAutomatic)
            Picker("AI style", selection: $profile.aiStyleID) {
              Text("Global").tag(String?.none)
              ForEach(styles) { style in Label(style.name, systemImage: style.symbol).tag(Optional(style.id)) }
            }
            .flowRow("AI style", caption: "For the automatic step and the box ✨.")
            Picker("Context from the text field", selection: $profile.contextUse) {
              Text("Global").tag(ContextUse?.none)
              ForEach(ContextUse.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            .flowRow("Context from the text field", caption: "What is used is set on the AI Post-Processing page.")
          }

          FlowGroup("Apps", footer: "An app belongs to one profile; adding it here removes it from another.") {
            ForEach(profile.apps) { app in
              FlowRow(app.name, caption: app.bundleID) {
                Button {
                  profile.apps.removeAll { $0.bundleID == app.bundleID }
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.flowQuiet)
                .accessibilityLabel("Remove \(app.name)")
              }
            }
            HStack(spacing: 8) {
              Spacer()
              Menu {
                ForEach(runningApps, id: \.bundleID) { app in
                  Button(app.name) { add(app) }
                }
              } label: {
                Label("Running app", systemImage: "plus")
              }
              .menuStyle(.button)
              .buttonStyle(.flowCompact)
              .fixedSize()
              Button("Choose app…") { chooseApp() }
                .buttonStyle(.flowCompact)
            }
          }
        }
      }
      HStack {
        if profile.isBuiltIn, !isNew {
          Button("Restore default") { onRestore(); dismiss() }
            .buttonStyle(.flow)
        }
        if !profile.isBuiltIn, !isNew {
          Button("Delete", role: .destructive) { confirmDelete = true }
            .buttonStyle(.flowDestructive)
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(.flowQuiet)
        Button("Save") { onSave(profile); dismiss() }
          .buttonStyle(.flowPrimary)
          .keyboardShortcut(.defaultAction)
          .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 640, height: 720)
    .background(FlowBackdrop())
    .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmDelete) {
      Button("Delete", role: .destructive) { onDelete(); dismiss() }
    } message: {
      Text("Its apps use the default profile again.")
    }
  }

  private var packSelection: Binding<String> {
    Binding(
      get: {
        guard let selected = profile.lexiconPacks else { return "global" }
        if selected.isEmpty { return "none" }
        if selected.count == 1 { return selected[0] }
        return "all"
      },
      set: { value in
        switch value {
        case "global": profile.lexiconPacks = nil
        case "none": profile.lexiconPacks = []
        case "all": profile.lexiconPacks = packs.map(\.id)
        default: profile.lexiconPacks = [value]
        }
      }
    )
  }

  private func triState(_ title: String, _ value: Binding<Bool?>) -> some View {
    FlowSegmented(selection: value, options: [FlowOption(Bool?.none, "Global"), FlowOption(Optional(true), "On"), FlowOption(Optional(false), "Off")], compact: true)
      .flowRow(title)
  }

  private var runningApps: [ProfileApp] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
      .compactMap { app in app.bundleIdentifier.map { ProfileApp(bundleID: $0, name: app.localizedName ?? $0) } }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func add(_ app: ProfileApp) {
    guard !profile.apps.contains(app) else { return }
    profile.apps.append(app)
  }

  private func chooseApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
      let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
      add(ProfileApp(bundleID: id, name: name))
    }
  }
}
