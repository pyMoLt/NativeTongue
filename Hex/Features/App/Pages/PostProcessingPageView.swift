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
  @State private var customLink = ""

  private var post: PostProcessingSettings { store.hexSettings.postProcessing }

  private func binding<Value>(_ keyPath: WritableKeyPath<PostProcessingSettings, Value>) -> Binding<Value> {
    Binding(
      get: { store.hexSettings.postProcessing[keyPath: keyPath] },
      set: { value in store.$hexSettings.withLock { $0.postProcessing[keyPath: keyPath] = value } }
    )
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader(
          title: "AI Post-Processing",
          subtitle: "A small language model on this Mac polishes your dictation. Off by default; nothing leaves your Mac.",
          symbol: "sparkles"
        )
        Card(title: "AI post-processing", systemImage: "power") {
          switchRow("Enable AI post-processing", \.enabled, "Runs after NativeTongue's own commands, numbers and vocabulary corrections.")
        }
        if post.enabled {
          automaticCard
          boxCard
          safetyCard
          memoryCard
          modelsCard
          advancedCard
        }
      }
      .padding(LocalASRDesign.pagePadding)
    }
    .task { models.refresh(settings: post) }
  }

  // MARK: Cards

  private var automaticCard: some View {
    Card(title: "After each dictation", systemImage: "wand.and.stars") {
      switchRow("Process automatically before inserting", \.autoEnabled, "The pill shows ✨ while the AI works. If the safety check finds a problem, your original text is inserted and the pill shows ⚠︎.")
      if post.autoEnabled {
        Picker("Applies to", selection: binding(\.autoScope)) {
          ForEach(PolishAutoScope.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        modePicker(binding(\.autoMode))
        modelPicker("Model", binding(\.autoModel), useCase: .auto)
        Stepper("Only from \(post.minimumWords) words", value: binding(\.minimumWords), in: 1 ... 50)
        Stepper("Time limit: \(post.timeoutSeconds) s, then the original is inserted", value: binding(\.timeoutSeconds), in: 3 ... 120)
      }
    }
  }

  private var boxCard: some View {
    Card(title: "Dictation box", systemImage: "text.below.photo") {
      switchRow("Show the ✨ button in the dictation box", \.boxButtonEnabled, "Click ✨ to run the AI on the box text. Afterwards the button turns into ⇄ to compare before and after.")
      if post.boxButtonEnabled {
        modePicker(binding(\.boxDefaultMode), title: "Button default")
        modelPicker("Model", binding(\.boxModel), useCase: .box)
        Toggle("Show the comparison automatically", isOn: binding(\.boxShowsDiffAutomatically))
          .toggleStyle(.switch)
      }
    }
  }

  private var safetyCard: some View {
    Card(title: "Safety check", systemImage: "checkmark.shield") {
      switchRow("Check the AI result", \.guardEnabled, "Compares numbers, doses, units, vocabulary terms, negations, code and length with your original. Strictness is under Advanced.")
    }
  }

  private var memoryCard: some View {
    Card(title: "Memory", systemImage: "memorychip") {
      Picker("Unload the model", selection: binding(\.unloadPolicy)) {
        ForEach(LLMUnloadPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      if post.unloadPolicy == .afterIdle {
        Picker("Idle time", selection: binding(\.idleUnloadMinutes)) {
          ForEach([1, 2, 5, 10, 30], id: \.self) { Text("\($0) min").tag($0) }
        }
      }
      Toggle("Load the model when you start dictating", isOn: binding(\.preloadOnHotkey))
        .toggleStyle(.switch)
      Text("Only one speech model is loaded at a time; the AI model may stay loaded next to it according to this setting.")
        .settingsCaption()
    }
  }

  private var modelsCard: some View {
    Card(title: "Models", systemImage: "cpu") {
      if let error = models.error {
        Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
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
        if model.id != LLMModelCatalog.all(settings: post).last?.id { Divider() }
      }
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        Text("Add a model from Hugging Face").font(.callout.weight(.semibold))
        HStack {
          TextField("https://huggingface.co/mlx-community/…  or  org/model", text: $customLink)
            .textFieldStyle(.roundedBorder)
          Button("Check") { models.check(customLink) }
            .buttonStyle(.glass)
            .disabled(customLink.trimmingCharacters(in: .whitespaces).isEmpty || models.isChecking)
        }
        if models.isChecking { ProgressView().controlSize(.small) }
        if let info = models.checked {
          customInfo(info)
        }
        Text("Only MLX models (safetensors) with a supported architecture can run. Checking reads the model page; nothing is downloaded until you click Install.")
          .settingsCaption()
      }
    }
  }

  private func customInfo(_ info: LLMRemoteInfo) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(info.repository).font(.callout.weight(.medium))
      Text("\(info.modelType ?? "unknown architecture") · \(ByteCountFormatter.string(fromByteCount: info.totalBytes, countStyle: .file)) · \(info.license ?? "license: see model page")")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !info.hasSafetensors || !info.isSupportedArchitecture || info.isGated {
        Label(
          info.isGated ? "This model requires accepting terms on Hugging Face." : "This repository is not a supported MLX model.",
          systemImage: "xmark.octagon"
        )
        .font(.caption)
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
        .buttonStyle(.glassProminent)
      }
    }
  }

  private var advancedCard: some View {
    Card {
      DisclosureGroup(isExpanded: $showsAdvanced) {
        VStack(alignment: .leading, spacing: 14) {
          Picker("Strictness · Clean up", selection: binding(\.cleanStrictness)) {
            ForEach(GuardStrictness.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          Picker("Strictness · Rewrite", selection: binding(\.rewriteStrictness)) {
            ForEach(GuardStrictness.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          Text("Strict: length, numbers, doses, terms, negations and code must match. Key facts: they must still appear (for rewriting). Length only: just large changes in length.")
            .settingsCaption()
          Stepper("Length tolerance ±\(post.lengthTolerancePercent) %", value: binding(\.lengthTolerancePercent), in: 5 ... 100, step: 5)
          promptEditor("Prompt · Clean up", mode: .clean)
          promptEditor("Prompt · Rewrite as task", mode: .rewrite)
          VStack(alignment: .leading, spacing: 4) {
            Text("What matters to me").font(.callout.weight(.semibold))
            TextEditor(text: binding(\.personalNote))
              .font(.callout)
              .frame(minHeight: 50)
              .scrollContentBackground(.hidden)
              .padding(6)
              .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Text("Added to both prompts, e.g. “Use British spelling” or “Write numbers below ten as words”.")
              .settingsCaption()
          }
          Button("Restore defaults (prompts and strictness)") {
            store.$hexSettings.withLock { settings in
              let defaults = PostProcessingSettings()
              settings.postProcessing.customCleanPrompt = nil
              settings.postProcessing.customRewritePrompt = nil
              settings.postProcessing.personalNote = ""
              settings.postProcessing.cleanStrictness = defaults.cleanStrictness
              settings.postProcessing.rewriteStrictness = defaults.rewriteStrictness
              settings.postProcessing.lengthTolerancePercent = defaults.lengthTolerancePercent
            }
          }
          .buttonStyle(.glass)
        }
        .padding(.top, 8)
      } label: {
        Label("Advanced: prompts and safety check", systemImage: "slider.horizontal.3").font(.headline)
      }
    }
  }

  // MARK: Pieces

  private func promptEditor(_ title: String, mode: PolishMode) -> some View {
    let keyPath: WritableKeyPath<PostProcessingSettings, String?> = mode == .clean ? \.customCleanPrompt : \.customRewritePrompt
    let text = Binding<String>(
      get: { store.hexSettings.postProcessing[keyPath: keyPath] ?? PolishPrompt.defaultPrompt(for: mode) },
      set: { value in
        store.$hexSettings.withLock {
          $0.postProcessing[keyPath: keyPath] = value == PolishPrompt.defaultPrompt(for: mode) ? nil : value
        }
      }
    )
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.callout.weight(.semibold))
        if post[keyPath: keyPath] != nil { Badge(text: "Edited", style: .accent) }
        Spacer()
        Button("Default") { store.$hexSettings.withLock { $0.postProcessing[keyPath: keyPath] = nil } }
          .buttonStyle(.borderless)
          .disabled(post[keyPath: keyPath] == nil)
      }
      TextEditor(text: text)
        .font(.system(.caption, design: .monospaced))
        .frame(minHeight: 160)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private func switchRow(_ title: String, _ keyPath: WritableKeyPath<PostProcessingSettings, Bool>, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(title, isOn: binding(keyPath)).toggleStyle(.switch)
      Text(caption).settingsCaption()
    }
  }

  private func modePicker(_ selection: Binding<PolishMode>, title: String = "Mode") -> some View {
    Picker(title, selection: selection) {
      ForEach(PolishMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
    }
    .pickerStyle(.segmented)
  }

  private func modelPicker(_ title: String, _ selection: Binding<String>, useCase: LLMModelDescriptor.UseCase) -> some View {
    let installed = LLMModelCatalog.all(settings: post).filter { models.installed.contains($0.id) }
    let selected = selection.wrappedValue
    let selectedMissing = !selected.isEmpty && !models.installed.contains(selected)
    return VStack(alignment: .leading, spacing: 2) {
      Picker(title, selection: selection) {
        if selected.isEmpty { Text("Choose a model").tag("") }
        if selectedMissing {
          let name = LLMModelCatalog.descriptor(id: selected, settings: post)?.displayName ?? selected
          Text("\(name) (not installed)").tag(selected)
        }
        ForEach(installed) { Text($0.displayName).tag($0.id) }
      }
      if installed.isEmpty {
        hint("No model installed yet — install one below.")
      } else if selected.isEmpty {
        hint("Choose which installed model to use.")
      } else if selectedMissing {
        hint("Not installed — install it below or choose another model.")
      }
    }
  }

  private func hint(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.orange)
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

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(model.displayName).font(.headline)
          if isInstalled {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Installed")
          }
          ForEach(usedFor, id: \.self) { Badge(text: $0, systemImage: "sparkles", style: .accent) }
        }
        Text(model.blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        FlowLayout {
          if model.recommendedFor.contains(.auto) { Badge(text: "Best for automatic", systemImage: "star.fill", style: .positive) }
          if model.recommendedFor.contains(.box) { Badge(text: "Best for the box", systemImage: "star.fill", style: .positive) }
          Badge(text: model.variant, systemImage: "square.stack.3d.up")
          Badge(text: speedText, systemImage: "speedometer")
          Badge(text: model.downloadSize, systemImage: "arrow.down.circle")
          Badge(text: model.license, systemImage: "doc.text")
          if model.experimental { Badge(text: "Experimental", systemImage: "flask", style: .caution) }
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 6) {
        if let progress {
          ProgressView(value: progress).frame(width: 110)
        } else if isInstalled {
          Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Remove model files")
        } else {
          Button { onInstall() } label: { Label("Install", systemImage: "arrow.down.circle") }
            .buttonStyle(.glassProminent)
        }
        if let onForget, progress == nil {
          Button("Remove from list", action: onForget).buttonStyle(.borderless).font(.caption)
        }
      }
      .controlSize(.small)
    }
    .confirmationDialog("Remove \(model.displayName)?", isPresented: $confirmRemove) {
      Button("Remove", role: .destructive, action: onRemove)
    } message: {
      Text("Frees \(model.downloadSize). You can install it again at any time.")
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
