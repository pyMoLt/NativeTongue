import ComposableArchitecture
import Dependencies
import HexCore
import LocalLLM
import SwiftUI

/// Settings → AI Post-Processing (plan 2.5, section 4.2): optional local
/// language model after the dictation pipeline. Everything is off by default.
struct PostProcessingPageView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var models = LLMModelManager()
  @State private var showsAdvanced = false
  @State private var editingStyle: AIStyle?
  @State private var showsContextAdvanced = false
  @State private var customLink = ""

  private var post: PostProcessingSettings { store.hexSettings.postProcessing }

  private func binding<Value>(_ keyPath: WritableKeyPath<PostProcessingSettings, Value>) -> Binding<Value> {
    Binding(
      get: { store.hexSettings.postProcessing[keyPath: keyPath] },
      set: { value in store.$hexSettings.withLock { $0.postProcessing[keyPath: keyPath] = value } }
    )
  }

  var body: some View {
    FlowPage(
      "AI Post-Processing",
      subtitle: "A small language model on this Mac polishes your dictation. Off by default; nothing leaves your Mac.",
      symbol: "sparkles"
    ) {
      FlowGroup {
        switchRow("Enable AI post-processing", \.enabled, "Runs after NativeTongue's own commands, numbers and vocabulary corrections.")
      }
      contextGroup
      if post.enabled {
        automaticGroup
        boxGroup
        safetyGroup
        memoryGroup
        modelsGroup
        advancedGroup
      }
    }
    .task { models.refresh(settings: post) }
  }

  // MARK: Groups

  private var automaticGroup: some View {
    FlowGroup("After each dictation") {
      switchRow("Process automatically before inserting", \.autoEnabled, "The pill shows ✨ while the AI works. If the safety check finds a problem, your original text is inserted and the pill shows ⚠︎.")
      if post.autoEnabled {
        Picker("Applies to", selection: binding(\.autoScope)) {
          ForEach(PolishAutoScope.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .flowRow("Applies to")
        stylePicker(binding(\.autoStyleID), title: "Style")
        modelPicker("Model", binding(\.autoModel), useCase: .auto)
        Stepper("", value: binding(\.minimumWords), in: 1 ... 50)
          .flowRow("Only from \(post.minimumWords) words")
        Stepper("", value: binding(\.timeoutSeconds), in: 3 ... 120)
          .flowRow("Time limit: \(post.timeoutSeconds) s", caption: "After that, the original is inserted.")
      }
    }
  }

  private var boxGroup: some View {
    FlowGroup("Dictation box") {
      switchRow("Show the ✨ button in the dictation box", \.boxButtonEnabled, "Click ✨ to run the AI on the box text. Afterwards the button turns into ⇄ to compare before and after.")
      if post.boxButtonEnabled {
        stylePicker(binding(\.boxStyleID), title: "Button default", caption: "Click ✨ for this style; its menu offers every style.")
        modelPicker("Model", binding(\.boxModel), useCase: .box)
        Toggle(isOn: binding(\.boxShowsDiffAutomatically)) { FlowLabel("Show the comparison automatically") }
      }
    }
  }

  private var safetyGroup: some View {
    FlowGroup("Safety check") {
      switchRow("Check the AI result", \.guardEnabled, "Compares numbers, doses, units, vocabulary terms, negations, code and length with your original. Each style has its own strictness (Advanced → Styles).")
    }
  }

  private func contextBinding<Value>(_ keyPath: WritableKeyPath<ContextSettings, Value>) -> Binding<Value> {
    Binding(
      get: { store.hexSettings.postProcessing.context[keyPath: keyPath] },
      set: { value in store.$hexSettings.withLock { $0.postProcessing.context[keyPath: keyPath] = value } }
    )
  }

  private var contextGroup: some View {
    let context = post.context
    return FlowGroup("Context from the text field", footer: "Read when you start dictating, analysed on this Mac and forgotten afterwards – never stored or logged. Names and capitals work without AI; the AI only gets the short hints, not the text. Profiles can choose their own setting (Profiles page).") {
      FlowSegmented(selection: contextBinding(\.use), options: [
        FlowOption(ContextUse.off, "Off"),
        FlowOption(.appOnly, "App only"),
        FlowOption(.analyzed, "Analyse the field"),
      ], compact: true)
      .flowRow("Use context", caption: "Off by default. Apps that do not show their text field to macOS (some web and chat apps) give the app name only.")
      if context.use == .analyzed {
        contextToggle("Continue the text", \.continuation, "Capitals and the space at the cursor fit what is already written.")
        contextToggle("Names and rare words", \.terms, "Names and terms already in the field keep their spelling (“maier” → “Meier” when “Meier” is written there).")
        contextToggle("Form of address", \.address, "Formal (Sie) or informal (du) like the surrounding text.")
        contextToggle("Language", \.language, "German or English like the surrounding text.")
        contextToggle("Kind of app", \.appType, "Mail, chat, code or AI assistant, from the app and its profile.")
        contextToggle("Lists", \.listFormat, "Inside a list item, the dictation stays one item.")
        FlowBlock {
          DisclosureGroup(isExpanded: $showsContextAdvanced) {
            VStack(alignment: .leading, spacing: FlowMetrics.pillSpacing) {
              Stepper("", value: contextBinding(\.characters), in: ContextSettings.characterRange, step: 100)
                .flowRow("Read \(context.characters) characters before the cursor", caption: "More text finds more names and a clearer form of address.")
              contextToggle("Also send the nearby text to the AI (experimental)", \.sendNearbyText, "The AI then sees the text before the cursor itself. It may get confused; the safety check still looks only at your dictation.")
            }
            .toggleStyle(FlowToggleStyle())
            .padding(.top, 8)
          } label: {
            Label("Advanced", systemImage: "slider.horizontal.3").flowFont(.subheadline, weight: .semibold, design: .rounded)
          }
        }
      }
    }
  }

  private func contextToggle(_ title: String, _ keyPath: WritableKeyPath<ContextSettings, Bool>, _ caption: String) -> some View {
    Toggle(isOn: contextBinding(keyPath)) { FlowLabel(title, caption: caption) }
  }

  private var memoryGroup: some View {
    FlowGroup("Memory", footer: "Only one speech model is loaded at a time; the AI model may stay loaded next to it according to this setting.") {
      Picker("Unload the model", selection: binding(\.unloadPolicy)) {
        ForEach(LLMUnloadPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      .flowRow("Unload the model")
      if post.unloadPolicy == .afterIdle {
        Picker("Idle time", selection: binding(\.idleUnloadMinutes)) {
          ForEach([1, 2, 5, 10, 30], id: \.self) { Text("\($0) min").tag($0) }
        }
        .flowRow("Idle time")
      }
      Toggle(isOn: binding(\.preloadOnHotkey)) { FlowLabel("Load the model when you start dictating") }
    }
  }

  private var modelsGroup: some View {
    FlowGroup("Models") {
      if let error = models.error {
        FlowNote(error, systemImage: "exclamationmark.triangle.fill", tone: .warning)
      }
      ForEach(LLMModelCatalog.all(settings: post)) { model in
        LLMModelRow(
          model: model,
          isInstalled: models.installed.contains(model.id),
          progress: models.progress[model.id],
          usedFor: usage(of: model),
          onInstall: { models.install(model, settings: post) { selectIfUnset(model) } },
          onRemove: { models.remove(model, settings: post) },
          onForget: model.isCustom ? { forgetCustom(model) } : nil
        )
      }
      FlowBlock {
        Text("Add a model from Hugging Face").flowFont(.callout, weight: .semibold)
        HStack(spacing: 8) {
          TextField("https://huggingface.co/mlx-community/…  or  org/model", text: $customLink)
            .flowField()
          Button("Check") { models.check(customLink) }
            .buttonStyle(.flow)
            .disabled(customLink.trimmingCharacters(in: .whitespaces).isEmpty || models.isChecking)
        }
        if models.isChecking { ProgressView().controlSize(.small) }
        if let info = models.checked {
          customInfo(info)
        }
        Text("Only MLX models (safetensors) with a supported architecture can run. Checking reads the model page; nothing is downloaded until you click Install.")
          .flowFont(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func customInfo(_ info: LLMRemoteInfo) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(info.repository).flowFont(.callout, weight: .medium)
      Text("\(info.modelType ?? "unknown architecture") · \(ByteCountFormatter.string(fromByteCount: info.totalBytes, countStyle: .file)) · \(info.license ?? "license: see model page")")
        .flowFont(.caption)
        .foregroundStyle(.secondary)
      if !info.hasSafetensors || !info.isSupportedArchitecture || info.isGated {
        Label(
          info.isGated ? "This model requires accepting terms on Hugging Face." : "This repository is not a supported MLX model.",
          systemImage: "xmark.octagon"
        )
        .flowFont(.caption)
        .foregroundStyle(.red)
      } else {
        Button("Add to list") {
          let model = CustomLLMModel(repository: info.repository, revision: info.revision, modelType: info.modelType, license: info.license, downloadBytes: info.totalBytes)
          store.$hexSettings.withLock { settings in
            settings.postProcessing.customModels.removeAll { $0.repository == model.repository }
            settings.postProcessing.customModels.append(model)
          }
          models.checked = nil
          customLink = ""
        }
        .buttonStyle(.flowPrimary)
      }
    }
  }

  private var advancedGroup: some View {
    FlowGroup("Advanced") {
      FlowBlock {
        DisclosureGroup(isExpanded: $showsAdvanced) {
          VStack(alignment: .leading, spacing: FlowMetrics.pillSpacing) {
            Toggle(isOn: binding(\.commandModeEnabled)) {
              FlowLabel("Command Mode", caption: "Select text in any app, press the Command Mode shortcut (Recording page) and say or type what to do – “shorter”, “as a list”, “in English”. The result appears with a comparison; ✓ replaces the selection.")
            }
            Text("Styles").flowFont(.callout, weight: .semibold).padding(.top, 8)
            ForEach(post.allStyles) { style in
              styleRow(style)
            }
            HStack {
              Spacer()
              Button {
                editingStyle = AIStyle.newCustom()
              } label: {
                Label("New style", systemImage: "plus")
              }
              .buttonStyle(.flow)
            }
            VStack(alignment: .leading, spacing: 6) {
              Text("What matters to me").flowFont(.callout, weight: .semibold)
              TextEditor(text: binding(\.personalNote))
                .flowFont(.callout)
                .frame(minHeight: 50)
                .scrollContentBackground(.hidden)
                .padding(10)
                .flowPanel()
              Text("Added to every style, e.g. “Use British spelling” or “Write numbers below ten as words”.")
                .flowFont(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            Button("Restore built-in styles") {
              store.$hexSettings.withLock { $0.postProcessing.editedStyles = [] }
            }
            .buttonStyle(.flow)
            .disabled(post.editedStyles.isEmpty)
            .padding(.top, 6)
          }
          .toggleStyle(FlowToggleStyle())
          .padding(.top, 10)
        } label: {
          Label("Styles, prompts and safety check", systemImage: "slider.horizontal.3").flowFont(.headline, design: .rounded)
        }
      }
    }
    .sheet(item: $editingStyle) { style in
      StyleEditor(
        style: style,
        isEdited: post.isEdited(style.id),
        isNew: !post.allStyles.contains { $0.id == style.id },
        onSave: { saved in store.$hexSettings.withLock { $0.postProcessing.save(saved) } },
        onRestore: { store.$hexSettings.withLock { $0.postProcessing.restoreDefault(style.id) } },
        onDelete: { store.$hexSettings.withLock { $0.postProcessing.deleteStyle(style.id) } }
      )
      .flowThemed(store.hexSettings.appearance)
    }
  }

  private func styleRow(_ style: AIStyle) -> some View {
    FlowRow(style.name, caption: styleCaption(style), systemImage: style.symbol) {
      HStack(spacing: 8) {
        if post.isEdited(style.id) { Badge(text: "Edited", style: .accent) }
        if style.isCustom { Badge(text: "Custom", systemImage: "person") }
        Button("Edit") { editingStyle = style }
          .buttonStyle(.flowCompact)
      }
    }
  }

  private func styleCaption(_ style: AIStyle) -> String {
    var parts = ["Safety check: \(style.strictness.displayName)"]
    if style.id == post.autoStyleID, post.autoEnabled { parts.append("automatic") }
    if style.id == post.boxStyleID, post.boxButtonEnabled { parts.append("box ✨") }
    return parts.joined(separator: " · ")
  }

  // MARK: Pieces

  private func stylePicker(_ selection: Binding<String>, title: String, caption: String? = nil) -> some View {
    Picker(title, selection: selection) {
      ForEach(post.allStyles) { style in
        Label(style.name, systemImage: style.symbol).tag(style.id)
      }
    }
    .flowRow(title, caption: caption)
  }

  private func switchRow(_ title: String, _ keyPath: WritableKeyPath<PostProcessingSettings, Bool>, _ caption: String) -> some View {
    Toggle(isOn: binding(keyPath)) { FlowLabel(title, caption: caption) }
  }

  private func modelPicker(_ title: String, _ selection: Binding<String>, useCase: LLMModelDescriptor.UseCase) -> some View {
    let installed = LLMModelCatalog.all(settings: post).filter { models.installed.contains($0.id) }
    let selected = selection.wrappedValue
    let selectedMissing = !selected.isEmpty && !models.installed.contains(selected)
    let hint: String? = installed.isEmpty ? "No model installed yet — install one below."
      : selected.isEmpty ? "Choose which installed model to use."
      : selectedMissing ? "Not installed — install it below or choose another model." : nil
    return VStack(alignment: .leading, spacing: 4) {
      Picker(title, selection: selection) {
        if selected.isEmpty { Text("Choose a model").tag("") }
        if selectedMissing {
          let name = LLMModelCatalog.descriptor(id: selected, settings: post)?.displayName ?? selected
          Text("\(name) (not installed)").tag(selected)
        }
        ForEach(installed) { Text($0.displayName).tag($0.id) }
      }
      .flowRow(title)
      if let hint { FlowNote(hint, systemImage: "exclamationmark.triangle.fill", tone: .warning) }
    }
  }

  private func usage(of model: LLMModelDescriptor) -> [String] {
    var uses: [String] = []
    if post.autoEnabled, post.autoModel == model.id { uses.append("Automatic") }
    if post.boxButtonEnabled, post.boxModel == model.id { uses.append("Box") }
    return uses
  }

  /// A freshly installed model fills empty selections (visible in the pickers);
  /// an explicit choice is never changed.
  private func selectIfUnset(_ model: LLMModelDescriptor) {
    store.$hexSettings.withLock {
      if $0.postProcessing.autoModel.isEmpty { $0.postProcessing.autoModel = model.id }
      if $0.postProcessing.boxModel.isEmpty { $0.postProcessing.boxModel = model.id }
    }
  }

  private func forgetCustom(_ model: LLMModelDescriptor) {
    models.remove(model, settings: post)
    store.$hexSettings.withLock { $0.postProcessing.customModels.removeAll { $0.id == model.id } }
  }
}

/// One language model in the list: friendly description, chips, install state.
private struct LLMModelRow: View {
  let model: LLMModelDescriptor
  let isInstalled: Bool
  let progress: Double?
  let usedFor: [String]
  let onInstall: () -> Void
  let onRemove: () -> Void
  let onForget: (() -> Void)?
  @State private var confirmRemove = false
  @Environment(\.flowTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        Text(model.displayName).flowFont(.headline, design: .rounded)
        if isInstalled {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent).accessibilityLabel("Installed")
        }
        ForEach(usedFor, id: \.self) { Badge(text: "In use: \($0)", systemImage: "sparkles", style: .accent) }
        Spacer(minLength: 8)
        trailing
      }
      Text(model.blurb).flowFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      FlowLayout {
        if model.recommendedFor.contains(.auto) { Badge(text: "Best for automatic", systemImage: "star.fill", style: .accent) }
        if model.recommendedFor.contains(.box) { Badge(text: "Best for the box", systemImage: "star.fill", style: .accent) }
        Badge(text: model.variant, systemImage: "square.stack.3d.up")
        Badge(text: speedText, systemImage: "speedometer")
        Badge(text: model.downloadSize, systemImage: "arrow.down.circle")
        Badge(text: model.license, systemImage: "doc.text")
        if model.experimental { Badge(text: "Experimental", systemImage: "flask") }
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .flowPanel()
    .confirmationDialog("Remove \(model.displayName)?", isPresented: $confirmRemove) {
      Button("Remove", role: .destructive, action: onRemove)
    } message: {
      Text("Frees \(model.downloadSize). You can install it again at any time.")
    }
  }

  @ViewBuilder
  private var trailing: some View {
    if let progress {
      ProgressView(value: progress).frame(width: 110)
    } else if isInstalled || onForget != nil {
      Menu {
        if isInstalled {
          Button(role: .destructive) { confirmRemove = true } label: { Label("Remove model files…", systemImage: "trash") }
        }
        if let onForget {
          Button("Remove from list", action: onForget)
        }
      } label: {
        Image(systemName: "ellipsis").frame(width: 18, height: 14)
      }
      .menuStyle(.button)
      .buttonStyle(.flowCompact)
      .fixedSize()
      .accessibilityLabel("More actions for \(model.displayName)")
      if !isInstalled {
        Button { onInstall() } label: { Label("Install", systemImage: "arrow.down.circle") }
          .buttonStyle(.flowPrimary)
      }
    } else {
      Button { onInstall() } label: { Label("Install · \(model.downloadSize)", systemImage: "arrow.down.circle") }
        .buttonStyle(.flowPrimary)
    }
  }

  private var speedText: String {
    switch model.speed {
    case .fastest: "Very fast"
    case .fast: "Fast"
    case .medium: "Medium"
    case .slow: "Slower"
    case .unknown: "Speed unknown"
    }
  }
}

/// Install state of the language models (downloads only on user action).
@MainActor
@Observable
final class LLMModelManager {
  var installed: Set<String> = []
  var progress: [String: Double] = [:]
  var error: String?
  var isChecking = false
  var checked: LLMRemoteInfo?

  @ObservationIgnored @Dependency(\.llm) private var llm

  func refresh(settings: PostProcessingSettings) {
    installed = Set(LLMModelCatalog.all(settings: settings).filter { llm.isInstalled($0) }.map(\.id))
  }

  func install(_ model: LLMModelDescriptor, settings: PostProcessingSettings, onInstalled: @escaping @MainActor () -> Void = {}) {
    error = nil
    progress[model.id] = 0
    Task {
      do {
        try await llm.install(model) { value in
          Task { @MainActor in self.progress[model.id] = value }
        }
      } catch {
        self.error = "Could not install \(model.displayName): \(error.localizedDescription)"
      }
      progress[model.id] = nil
      refresh(settings: settings)
      if installed.contains(model.id) { onInstalled() }
    }
  }

  func remove(_ model: LLMModelDescriptor, settings: PostProcessingSettings) {
    Task {
      do { try await llm.remove(model) } catch { self.error = error.localizedDescription }
      refresh(settings: settings)
    }
  }

  func check(_ link: String) {
    isChecking = true
    checked = nil
    error = nil
    Task {
      do { checked = try await llm.remoteInfo(link) } catch { self.error = error.localizedDescription }
      isChecking = false
    }
  }
}

/// Edits one style: name, instruction, example, safety check.
private struct StyleEditor: View {
  @State var style: AIStyle
  let isEdited: Bool
  let isNew: Bool
  let onSave: (AIStyle) -> Void
  let onRestore: () -> Void
  let onDelete: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var confirmDelete = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PageHeader(
        title: isNew ? "New style" : style.name,
        subtitle: style.isBuiltIn ? "Built-in style – you can change its prompt and restore it any time" : "Your own style for the box, automatic step, files, Command Mode and profiles",
        symbol: style.symbol
      )
      ScrollView {
        VStack(alignment: .leading, spacing: FlowMetrics.pillSpacing) {
          FlowRow("Name") {
            TextField("Name", text: $style.name)
              .textFieldStyle(.plain)
              .multilineTextAlignment(.trailing)
              .frame(width: 240)
              .disabled(style.isBuiltIn)
          }
          Text("Instruction").flowFont(.callout, weight: .semibold).padding(.top, 6)
          TextEditor(text: $style.instruction)
            .flowFont(.caption, monospaced: true)
            .frame(minHeight: 150)
            .scrollContentBackground(.hidden)
            .padding(10)
            .flowPanel()
          Text("Example (optional) – one input and the output you want. It helps the small model a lot.")
            .flowFont(.callout, weight: .semibold).padding(.top, 6)
          TextEditor(text: $style.exampleInput)
            .flowFont(.callout)
            .frame(minHeight: 44)
            .scrollContentBackground(.hidden)
            .padding(10)
            .flowPanel()
            .overlay(alignment: .topLeading) {
              if style.exampleInput.isEmpty { placeholder("Example input") }
            }
          TextEditor(text: $style.exampleOutput)
            .flowFont(.callout)
            .frame(minHeight: 60)
            .scrollContentBackground(.hidden)
            .padding(10)
            .flowPanel()
            .overlay(alignment: .topLeading) {
              if style.exampleOutput.isEmpty { placeholder("Example output") }
            }
          FlowSegmented(selection: $style.strictness, options: GuardStrictness.allCases.map { FlowOption($0, $0.displayName) }, compact: true)
            .flowRow("Safety check", caption: "Strict: length, numbers, terms and negations must match. Key facts: they must still appear. Length only: big changes in length. Off: for summaries and lists.")
          Stepper("", value: $style.lengthTolerancePercent, in: 5 ... 200, step: 5)
            .flowRow("Length tolerance ±\(style.lengthTolerancePercent) %")
        }
      }
      HStack {
        if style.isBuiltIn, isEdited {
          Button("Restore default") { onRestore(); dismiss() }
            .buttonStyle(.flow)
        }
        if style.isCustom, !isNew {
          Button("Delete", role: .destructive) { confirmDelete = true }
            .buttonStyle(.flowDestructive)
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(.flowQuiet)
        Button("Save") { onSave(style); dismiss() }
          .buttonStyle(.flowPrimary)
          .keyboardShortcut(.defaultAction)
          .disabled(style.name.trimmingCharacters(in: .whitespaces).isEmpty || style.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 620, height: 700)
    .background(FlowBackdrop())
    .confirmationDialog("Delete \(style.name)?", isPresented: $confirmDelete) {
      Button("Delete", role: .destructive) { onDelete(); dismiss() }
    } message: {
      Text("Selections that used it switch to Clean up.")
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text).flowFont(.callout).foregroundStyle(.tertiary).padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
  }
}
