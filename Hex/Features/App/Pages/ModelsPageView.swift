import ComposableArchitecture
import HexCore
import SwiftUI

/// „Modelle“: cards grouped by purpose with badges and measured values (plan 5.10).
struct ModelsPageView: View {
  @Bindable var store: StoreOf<ModelDownloadFeature>
  private let benchmarks = try? ModelBenchmarkCatalog.load()

  private var groups: [(LocalASRModelGroup, [LocalASRModelDescriptor])] {
    let order: [LocalASRModelGroup] = [.recommended, .general, .medical, .experimental]
    return order.compactMap { group in
      let models = LocalASRModelCatalog.bundled.filter { $0.group == group }
      return models.isEmpty ? nil : (group, models)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PageHeader(title: "Models", subtitle: "Everything runs on this Mac. Only one model is loaded at a time.", symbol: "cpu")
        if let error = store.downloadError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
        }
        RecommendationsCard()
        ForEach(groups, id: \.0) { group, models in
          VStack(alignment: .leading, spacing: 10) {
            Text(group.title).font(.title3.weight(.semibold))
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
          Text("Measurements: one speaker, \(benchmarks.literalCommandReferenceCount) literal commands, \(benchmarks.terminologyReferenceCount) domain terms, measured \(benchmarks.measuredAt). Memory = peak process memory; Core ML / Neural Engine memory may not be fully included.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(LocalASRDesign.pagePadding)
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
private struct RecommendationsCard: View {
  private var rows: [(String, String, [LocalASRModelDescriptor])] {
    let all = LocalASRModelCatalog.bundled
    return [
      ("Normal", "waveform", all.filter { $0.recommendedFor.contains(.normal) }),
      ("Literal", "paragraphsign", all.filter { $0.recommendedFor.contains(.literal) }),
      ("Streaming", "dot.radiowaves.left.and.right", all.filter(\.recommendedForStreaming)),
    ].filter { !$0.2.isEmpty }
  }

  var body: some View {
    Card(title: "Recommended per mode", systemImage: "star") {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(rows, id: \.0) { title, symbol, models in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: symbol)
              .font(.callout.weight(.semibold))
              .frame(width: 110, alignment: .leading)
            Text(models.map { $0.displayName.components(separatedBy: " · ").first ?? $0.displayName }.joined(separator: ", "))
              .font(.callout)
              .foregroundStyle(.secondary)
          }
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

  private var supportsBiasing: Bool {
    model.capabilities.contextPrompt || !model.capabilities.biasing.isEmpty
  }

  var body: some View {
    Card {
      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          header
          if let blurb = model.blurb {
            Text(blurb)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          FlowBadges(model: model)
          if let measurement, let benchmarks {
            HStack(spacing: 16) {
              metric("Commands", "\(measurement.literalCommandsRecognized)/\(benchmarks.literalCommandReferenceCount)")
              metric("Terms", "\(measurement.terminologyCorrect)/\(benchmarks.terminologyReferenceCount)")
              metric("WER", "\(Self.decimal(measurement.wordErrorRatePercent)) %")
              metric("RAM", "\(Self.decimal(measurement.peakProcessRSSGB)) GB")
              metric("\(benchmarks.terminologyAudioSeconds) s audio", "\(Self.decimal(measurement.transcriptionSeconds)) s")
            }
            .padding(.top, 2)
          } else {
            Text("Not measured yet on this Mac.")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          if supportsBiasing {
            Toggle("Context biasing with your vocabulary (experimental)", isOn: Binding(get: { biasingEnabled }, set: onBiasing))
              .toggleStyle(.switch)
              .controlSize(.small)
              .font(.callout)
          }
          DisclosureGroup(isExpanded: $showDetails) {
            details.padding(.top, 4)
          } label: {
            Text("Details").font(.caption.weight(.medium)).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        actions
      }
    }
    .confirmationDialog("Remove \(model.displayName)?", isPresented: $confirmDelete) {
      Button("Remove", role: .destructive, action: onDelete)
    } message: {
      Text("Frees \(model.storageSize). You can reinstall it at any time.")
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(model.displayName).font(.headline)
      RuntimeChip(backend: model.backend)
      if isInstalled {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .help("Installed")
          .accessibilityLabel("Installed")
      }
      if isNormalModel, !model.streamingOnly { Badge(text: "Normal", systemImage: "waveform", style: .accent) }
      if isLiteralModel, !model.streamingOnly { Badge(text: "Literal", systemImage: "paragraphsign", style: .accent) }
      if isStreamingModel { Badge(text: "Streaming", systemImage: "dot.radiowaves.left.and.right", style: .accent) }
    }
  }

  private var details: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
      detailRow("Runtime", model.backend.displayName)
      detailRow("Precision", model.precision)
      detailRow("Size", "\(model.size) · \(model.storageSize)")
      detailRow("License", model.license)
      detailRow("Source", model.revision.map { "\(model.repository) @ \($0.prefix(8))" } ?? model.repository)
      detailRow("Languages", model.languages.joined(separator: ", "))
    }
    .font(.caption)
  }

  private func detailRow(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled).lineLimit(2)
    }
  }

  @ViewBuilder
  private var actions: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if isDownloading {
        ProgressView(value: progress)
          .frame(width: 120)
        Button("Cancel", action: onCancel).buttonStyle(.glass).controlSize(.small)
      } else if isInstalled {
        if !model.streamingOnly {
          Button(isNormalModel ? "Normal model ✓" : "Use for Normal", action: onUseNormal)
            .buttonStyle(.glass)
            .disabled(isNormalModel)
          Button(isLiteralModel ? "Literal model ✓" : "Use for Literal", action: onUseLiteral)
            .buttonStyle(.glass)
            .disabled(isLiteralModel)
        }
        if model.streaming != .none {
          Button(isStreamingModel ? "Streaming model ✓" : "Use for Streaming", action: onUseStreaming)
            .buttonStyle(.glass)
            .disabled(isStreamingModel)
        }
        Button(role: .destructive) { confirmDelete = true } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Remove model")
        .accessibilityLabel("Remove \(model.displayName)")
      } else {
        Button {
          onInstall()
        } label: {
          Label("Install", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.glassProminent)
        Text(model.storageSize).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .controlSize(.small)
  }

  static func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(.callout.monospacedDigit().weight(.semibold))
      Text(title).font(.caption2).foregroundStyle(.secondary)
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
    Label(label.0, systemImage: label.1)
      .font(.caption2.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
  }
}

private struct FlowBadges: View {
  let model: LocalASRModelDescriptor

  var body: some View {
    FlowLayout {
      ForEach(recommendations, id: \.self) { mode in
        Badge(text: "Best for \(mode)", systemImage: "star.fill", style: .positive)
      }
      model.literalRating.badge
      model.streaming.badge
      if model.capabilities.wordTimings { Badge(text: "Timestamps", systemImage: "clock") }
      if model.capabilities.supportsAutoLanguage { Badge(text: "Auto language", systemImage: "globe") }
      if model.capabilities.contextPrompt || !model.capabilities.biasing.isEmpty { Badge(text: "Biasing", systemImage: "text.book.closed") }
      let codes = model.languages.filter { $0.count <= 3 }.map { $0.uppercased() }
      let extra = model.languages.count - codes.count
      Badge(text: codes.prefix(4).joined(separator: " ") + (codes.count > 4 ? " +\(codes.count - 4)" : "") + (extra > 0 ? " +more" : ""), systemImage: "character.bubble")
    }
  }

  private var recommendations: [String] {
    var modes: [String] = []
    if model.recommendedFor.contains(.normal) { modes.append("Normal") }
    if model.recommendedFor.contains(.literal) { modes.append("Literal") }
    if model.recommendedForStreaming { modes.append("Streaming") }
    return modes
  }
}
