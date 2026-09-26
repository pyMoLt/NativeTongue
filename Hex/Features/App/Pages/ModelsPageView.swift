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
        ForEach(groups, id: \.0) { group, models in
          VStack(alignment: .leading, spacing: 10) {
            Text(group.title).font(.title3.weight(.semibold))
            ForEach(models) { model in
              ModelCard(
                model: model,
                isInstalled: isInstalled(model),
                isNormalModel: store.hexSettings.selectedModel == model.internalName,
                isLiteralModel: store.hexSettings.model(for: .literal) == model.internalName,
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

private struct ModelCard: View {
  let model: LocalASRModelDescriptor
  let isInstalled: Bool
  let isNormalModel: Bool
  let isLiteralModel: Bool
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
  let onBiasing: (Bool) -> Void
  @State private var confirmDelete = false

  private var supportsBiasing: Bool {
    model.capabilities.contextPrompt || !model.capabilities.biasing.isEmpty
  }

  var body: some View {
    Card {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text(model.displayName).font(.headline)
            if isNormalModel { Badge(text: "Normal", systemImage: "waveform", style: .accent) }
            if isLiteralModel { Badge(text: "Literal", systemImage: "paragraphsign", style: .accent) }
          }
          Text("\(model.backend.displayName) · \(model.storageSize) · \(model.license)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          FlowBadges(model: model)
          if let measurement, let benchmarks {
            HStack(spacing: 14) {
              metric("Commands", "\(measurement.literalCommandsRecognized)/\(benchmarks.literalCommandReferenceCount)")
              metric("Terms", "\(measurement.terminologyCorrect)/\(benchmarks.terminologyReferenceCount)")
              metric("WER", "\(Self.decimal(measurement.wordErrorRatePercent)) %")
              metric("RAM", "\(Self.decimal(measurement.peakProcessRSSGB)) GB")
              metric("Time for \(benchmarks.terminologyAudioSeconds) s audio", "\(Self.decimal(measurement.transcriptionSeconds)) s")
            }
            .padding(.top, 2)
          }
          if supportsBiasing {
            Toggle("Context biasing with your vocabulary (experimental)", isOn: Binding(get: { biasingEnabled }, set: onBiasing))
              .toggleStyle(.switch)
              .controlSize(.small)
              .font(.callout)
          }
        }
        Spacer(minLength: 8)
        actions
      }
    }
    .confirmationDialog("\(model.displayName) entfernen?", isPresented: $confirmDelete) {
      Button("Remove", role: .destructive, action: onDelete)
    } message: {
      Text("Gibt \(model.storageSize) frei. Du kannst es jederzeit neu installieren.")
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
        Button(isNormalModel ? "Normal model ✓" : "Use for Normal", action: onUseNormal)
          .buttonStyle(.glass)
          .disabled(isNormalModel)
        Button(isLiteralModel ? "Literal model ✓" : "Use for Literal", action: onUseLiteral)
          .buttonStyle(.glass)
          .disabled(isLiteralModel)
        Button(role: .destructive) { confirmDelete = true } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Remove model")
      } else {
        Button {
          onInstall()
        } label: {
          Label("Install", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.glassProminent)
      }
    }
    .controlSize(.small)
  }

  static func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "de_DE")))
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(.callout.monospacedDigit().weight(.semibold))
      Text(title).font(.caption2).foregroundStyle(.secondary)
    }
  }
}

private struct FlowBadges: View {
  let model: LocalASRModelDescriptor

  var body: some View {
    HStack(spacing: 6) {
      model.literalRating.badge
      if model.capabilities.wordTimings { Badge(text: "Timestamps", systemImage: "clock") }
      if model.capabilities.supportsAutoLanguage { Badge(text: "Auto language", systemImage: "globe") }
      if model.capabilities.contextPrompt || !model.capabilities.biasing.isEmpty { Badge(text: "Biasing", systemImage: "text.book.closed") }
      let codes = model.languages.filter { $0.count <= 3 }.map { $0.uppercased() }
      let extra = model.languages.count - codes.count
      Badge(text: codes.prefix(4).joined(separator: " ") + (codes.count > 4 ? " +\(codes.count - 4)" : "") + (extra > 0 ? " + weitere" : ""), systemImage: "character.bubble")
    }
  }
}
