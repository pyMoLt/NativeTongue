import ComposableArchitecture
import HexCore
import SwiftUI

/// „Modelle“: cards grouped by purpose with badges and measured values (plan 5.10).
struct ModelsPageView: View {
  @Bindable var store: StoreOf<ModelDownloadFeature>
  /// Minutes after which an idle speech model is unloaded (0 = never).
  var idleUnloadMinutes: Binding<Int>
  private let benchmarks = try? ModelBenchmarkCatalog.load()

  private var groups: [(LocalASRModelGroup, [LocalASRModelDescriptor])] {
    let order: [LocalASRModelGroup] = [.recommended, .general, .medical, .experimental]
    return order.compactMap { group in
      let models = LocalASRModelCatalog.bundled.filter { $0.group == group }
      return models.isEmpty ? nil : (group, models)
    }
  }

  var body: some View {
    FlowPage("Models", subtitle: "Everything runs on this Mac. Only one speech model is loaded at a time.", symbol: "cpu") {
      if let error = store.downloadError {
        FlowNote(error, systemImage: "exclamationmark.triangle.fill", tone: .warning)
      }
      RecommendationsGroup()
      FlowGroup("Memory", footer: "Saves memory. The model loads again the next time you press the dictation key.") {
        Picker("Unload idle model", selection: idleUnloadMinutes) {
          Text("Never").tag(0)
          Text("After 2 minutes").tag(2)
          Text("After 5 minutes").tag(5)
          Text("After 10 minutes").tag(10)
          Text("After 30 minutes").tag(30)
        }
        .flowRow("Unload an idle model")
      }
      ForEach(groups, id: \.0) { group, models in
        FlowGroup(group.title) {
          ForEach(models) { model in
            ModelCard(
              model: model,
              isInstalled: isInstalled(model),
              isNormalModel: store.hexSettings.selectedModel == model.internalName,
              isLiteralModel: store.hexSettings.model(for: .literal) == model.internalName,
              isStreamingModel: store.hexSettings.model(for: .streaming) == model.internalName,
              isDownloading: store.downloadingModelName == model.internalName,
              progress: store.downloadProgress,
              measurement: benchmarks?.measurement(for: model.internalName, configuration: .punctuationSuppressed)
                ?? benchmarks?.measurement(for: model.internalName, configuration: .natural),
              benchmarks: benchmarks,
              biasingEnabled: store.hexSettings.isBiasingEnabled(for: model.internalName),
              onInstall: { store.send(.downloadModel(model.internalName)) },
              onCancel: { store.send(.cancelDownload) },
              onDelete: { store.send(.deleteModel(model.internalName)) },
              onUseNormal: { store.send(.selectModel(model.internalName)) },
              onUseLiteral: {
                store.$hexSettings.withLock { settings in
                  settings.literalModel = settings.selectedModel == model.internalName ? "" : model.internalName
                }
              },
              onUseStreaming: {
                store.$hexSettings.withLock { settings in
                  settings.streaming.model = model.internalName == StreamingSettings.recommendedModel ? "" : model.internalName
                }
              },
              onBiasing: { value in store.$hexSettings.withLock { $0.modelBiasing[model.internalName] = value } }
            )
          }
        }
      }
      if let benchmarks {
        FlowNote("Measurements: one speaker, \(benchmarks.literalCommandReferenceCount) literal commands, \(benchmarks.terminologyReferenceCount) domain terms, measured \(benchmarks.measuredAt). Memory = peak process memory; Core ML / Neural Engine memory may not be fully included.")
      }
    }
    .task {
      if store.availableModels.isEmpty { store.send(.fetchModels) }
    }
  }

  private func isInstalled(_ model: LocalASRModelDescriptor) -> Bool {
    store.availableModels.first { $0.name == model.internalName }?.isDownloaded ?? false
  }
}

/// Which model to pick for which mode, at a glance (audit A14: per mode,
/// not one global "recommended").
private struct RecommendationsGroup: View {
  private var rows: [(String, String, [LocalASRModelDescriptor])] {
    let all = LocalASRModelCatalog.bundled
    return [
      ("Normal", "waveform", all.filter { $0.recommendedFor.contains(.normal) }),
      ("Literal", "paragraphsign", all.filter { $0.recommendedFor.contains(.literal) }),
      ("Streaming", "dot.radiowaves.left.and.right", all.filter(\.recommendedForStreaming)),
    ].filter { !$0.2.isEmpty }
  }

  var body: some View {
    FlowGroup("Recommended per mode") {
      ForEach(rows, id: \.0) { title, symbol, models in
        FlowRow(title, systemImage: symbol) {
          Text(models.map { $0.displayName.components(separatedBy: " · ").first ?? $0.displayName }.joined(separator: ", "))
            .flowFont(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct ModelCard: View {
  let model: LocalASRModelDescriptor
  let isInstalled: Bool
  let isNormalModel: Bool
  let isLiteralModel: Bool
  let isStreamingModel: Bool
  let isDownloading: Bool
  let progress: Double
  let measurement: ModelBenchmarkMeasurement?
  let benchmarks: ModelBenchmarkCatalog?
  let biasingEnabled: Bool
  let onInstall: () -> Void
  let onCancel: () -> Void
  let onDelete: () -> Void
  let onUseNormal: () -> Void
  let onUseLiteral: () -> Void
  let onUseStreaming: () -> Void
  let onBiasing: (Bool) -> Void
  @State private var confirmDelete = false
  @State private var showDetails = false
  @Environment(\.flowTheme) private var theme

  private var supportsBiasing: Bool {
    model.capabilities.contextPrompt || !model.capabilities.biasing.isEmpty
  }

  var body: some View {
    FlowBlock(padding: 18) {
      header
      if let blurb = model.blurb {
        Text(blurb)
          .flowFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ModelChips(model: model)
      if let measurement, let benchmarks {
        HStack(spacing: 18) {
          metric("Commands", "\(measurement.literalCommandsRecognized)/\(benchmarks.literalCommandReferenceCount)")
          metric("Terms", "\(measurement.terminologyCorrect)/\(benchmarks.terminologyReferenceCount)")
          metric("WER", "\(Self.decimal(measurement.wordErrorRatePercent)) %")
          metric("RAM", "\(Self.decimal(measurement.peakProcessRSSGB)) GB")
          metric("\(benchmarks.terminologyAudioSeconds) s audio", "\(Self.decimal(measurement.transcriptionSeconds)) s")
        }
      }
      if isInstalled {
        usePills
      }
      if supportsBiasing, isInstalled {
        HStack {
          Text("Context biasing with your vocabulary (experimental)").flowFont(.callout)
          Spacer()
          Toggle("", isOn: Binding(get: { biasingEnabled }, set: onBiasing))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
      }
      DisclosureGroup(isExpanded: $showDetails) {
        details.padding(.top, 4)
      } label: {
        Text("Details").flowFont(.caption, weight: .medium).foregroundStyle(.secondary)
      }
    }
    .confirmationDialog("Remove \(model.displayName)?", isPresented: $confirmDelete) {
      Button("Remove", role: .destructive, action: onDelete)
    } message: {
      Text("Frees \(model.storageSize). You can reinstall it at any time.")
    }
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center, spacing: 8) {
      Text(model.displayName)
        .flowFont(.headline, design: .rounded)
        .lineLimit(2)
      if isInstalled {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(theme.accent)
          .help("Installed")
          .accessibilityLabel("Installed")
      }
      Spacer(minLength: 8)
      trailingAction
    }
  }

  @ViewBuilder
  private var trailingAction: some View {
    if isDownloading {
      HStack(spacing: 8) {
        ProgressView(value: progress).frame(width: 110)
        Button("Cancel", action: onCancel).buttonStyle(.flowCompact)
      }
    } else if isInstalled {
      // Removing is tucked into a menu, away from the "Use for" buttons.
      Menu {
        Button(role: .destructive) { confirmDelete = true } label: {
          Label("Remove model…", systemImage: "trash")
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 18, height: 14)
      }
      .menuStyle(.button)
      .buttonStyle(.flowCompact)
      .fixedSize()
      .help("More")
      .accessibilityLabel("More actions for \(model.displayName)")
    } else {
      Button(action: onInstall) {
        Label("Install · \(model.storageSize)", systemImage: "arrow.down.circle")
      }
      .buttonStyle(.flowPrimary)
    }
  }

  // MARK: Use for

  private var usePills: some View {
    HStack(spacing: 6) {
      Text("Use for")
        .flowFont(.caption, weight: .semibold)
        .foregroundStyle(.secondary)
        .frame(width: 52, alignment: .leading)
      if !model.streamingOnly {
        usePill("Normal", "waveform", selected: isNormalModel, action: onUseNormal)
        usePill("Literal", "paragraphsign", selected: isLiteralModel, action: onUseLiteral)
      }
      if model.streaming != .none {
        usePill("Streaming", "dot.radiowaves.left.and.right", selected: isStreamingModel, action: onUseStreaming)
      }
      // Always three equal slots, so the pills line up across all cards.
      let shown = (model.streamingOnly ? 0 : 2) + (model.streaming == .none ? 0 : 1)
      ForEach(0 ..< max(0, 3 - shown), id: \.self) { _ in
        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
      }
    }
  }

  private func usePill(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button { if !selected { action() } } label: {
      HStack(spacing: 5) {
        Image(systemName: selected ? "checkmark" : symbol).flowFont(.caption, weight: .semibold)
        Text(title).flowFont(.callout, weight: selected ? .semibold : .regular)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
      .foregroundStyle(selected ? Color.white : Color.primary)
      .background {
        if selected {
          Capsule().fill(LinearGradient(colors: [theme.accent, theme.companion], startPoint: .leading, endPoint: .trailing))
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .flowSurface(Capsule(), interactive: !selected)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityLabel(selected ? "\(title) model (in use)" : "Use for \(title)")
  }

  // MARK: Details

  private var details: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
      detailRow("Spoken punctuation", Self.literalText(model.literalRating))
      detailRow("Streaming", Self.streamingText(model.streaming))
      detailRow("Runtime", model.backend.displayName)
      detailRow("Precision", model.precision)
      detailRow("Size", "\(model.size) · \(model.storageSize)")
      detailRow("License", model.license)
      detailRow("Source", model.revision.map { "\(model.repository) @ \($0.prefix(8))" } ?? model.repository)
      detailRow("Languages", model.languages.joined(separator: ", "))
      if measurement == nil {
        detailRow("Measured", "Not measured yet on this Mac")
      }
    }
    .flowFont(.caption)
  }

  static func literalText(_ rating: LocalASRLiteralRating) -> String {
    switch rating {
    case .reliable: "Very reliable in Literal mode"
    case .limited: "Works; the model sometimes sets marks on its own"
    case .unverified: "Not tested yet"
    case .unsuitable: "Better for Normal mode"
    }
  }

  static func streamingText(_ support: LocalASRStreamingSupport) -> String {
    switch support {
    case .native: "Live while you speak"
    case .emulated: "Typed after short pauses"
    case .none: "Not available"
    }
  }

  private func detailRow(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled).lineLimit(2)
    }
  }

  static func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).flowFont(.callout, weight: .semibold, monospacedDigit: true)
      Text(title).flowFont(.caption2).foregroundStyle(.secondary)
    }
  }
}

/// Where the model runs: Neural Engine (Core ML), GPU (MLX) or macOS itself.
private struct RuntimeChip: View {
  let backend: LocalASRBackend

  private var label: (String, String) {
    switch backend {
    case .whisperKitCoreML, .parakeetFluidAudioCoreML, .canaryFluidAudioCoreML, .omiMedicalParakeetCoreML, .nemotronStreamingCoreML:
      ("Neural Engine", "cpu")
    case .qwen3MLX, .cohereMLX, .voxtralRealtimeMLX:
      ("GPU", "square.stack.3d.up")
    case .appleSpeechAnalyzer:
      ("macOS", "apple.logo")
    }
  }

  var body: some View {
    Badge(text: label.0, systemImage: label.1)
  }
}

/// Positive "best for" chips in the accent colour, then neutral facts.
struct ModelChips: View {
  let model: LocalASRModelDescriptor

  var body: some View {
    FlowLayout {
      ForEach(model.bestFor, id: \.self) { mode in
        Badge(text: "Best for \(mode)", systemImage: "star.fill", style: .accent)
      }
      RuntimeChip(backend: model.backend)
      if model.streaming == .native { Badge(text: "Live streaming", systemImage: "dot.radiowaves.left.and.right") }
      if model.capabilities.wordTimings { Badge(text: "Timestamps", systemImage: "clock") }
      if model.capabilities.supportsAutoLanguage { Badge(text: "Auto language", systemImage: "globe") }
      if model.capabilities.contextPrompt || !model.capabilities.biasing.isEmpty { Badge(text: "Vocabulary biasing", systemImage: "text.book.closed") }
      let codes = model.languages.filter { $0.count <= 3 }.map { $0.uppercased() }
      let extra = model.languages.count - codes.count
      Badge(text: codes.prefix(4).joined(separator: " ") + (codes.count > 4 ? " +\(codes.count - 4)" : "") + (extra > 0 ? " +more" : ""), systemImage: "character.bubble")
    }
  }
}

extension LocalASRModelDescriptor {
  /// Modes this model is recommended for, in display order.
  var bestFor: [String] {
    var modes: [String] = []
    if recommendedFor.contains(.normal) { modes.append("Normal") }
    if recommendedFor.contains(.literal) { modes.append("Literal") }
    if recommendedForStreaming { modes.append("Streaming") }
    return modes
  }
}
