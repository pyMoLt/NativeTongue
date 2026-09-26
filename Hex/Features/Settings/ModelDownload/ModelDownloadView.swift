import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

private func modelNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
	ModelPatternMatcher.namesMatch(lhs, rhs)
}

public struct ModelDownloadView: View {
	@ObserveInjection var inject

	@Bindable var store: StoreOf<ModelDownloadFeature>
	@State private var isModelLibraryPresented = false
	var shouldFlash: Bool = false

	public init(store: StoreOf<ModelDownloadFeature>, shouldFlash: Bool = false) {
		self.store = store
		self.shouldFlash = shouldFlash
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if !store.modelBootstrapState.isModelReady,
			   let message = store.modelBootstrapState.lastError,
			   !message.isEmpty
			{
				AutoDownloadBannerView(
					title: "Download failed",
					subtitle: message,
					progress: nil,
					style: .error
				)
			}
			if selectedModelName == nil, downloadingModel == nil {
				NoModelChooser(
					isLoading: store.isLoadingModels,
					isFlashing: shouldFlash,
					onBrowse: { isModelLibraryPresented = true },
					onRetry: { store.send(.fetchModels) }
				)
			} else {
				CurrentModelSummary(
					model: selectedModel,
					selectedModelName: selectedModelName,
					isInstalled: store.selectedModelIsDownloaded,
					isDownloadingAnything: store.isDownloading,
					downloadingModel: downloadingModel,
					downloadProgress: store.downloadProgress,
					onBrowse: { isModelLibraryPresented = true },
					onDownload: {
						if let name = selectedModelName {
							store.send(.downloadModel(name))
						}
					},
					onCancelDownload: { store.send(.cancelDownload) }
				)
			}
			if let err = store.downloadError,
			   err != store.modelBootstrapState.lastError
			{
				Text("Model Error: \(err)")
					.foregroundColor(.red)
					.font(.caption)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.sheet(isPresented: $isModelLibraryPresented) {
			ModelLibrarySheet(store: store)
		}
		.task {
			if store.availableModels.isEmpty {
				store.send(.fetchModels)
			}
		}
		.enableInjection()
	}

	private var selectedModel: CuratedModelInfo? {
		guard let selectedModelName else { return nil }
		return store.curatedModels.first { model in
			modelNamesMatch(model.internalName, selectedModelName)
		}
	}

	private var selectedModelName: String? {
		store.selectedModelNameForDisplay
	}

	private var downloadingModel: CuratedModelInfo? {
		guard let downloadingModelName = store.downloadingModelName else { return nil }
		return store.curatedModels.first { model in
			modelNamesMatch(model.internalName, downloadingModelName)
		}
	}

}

private struct NoModelChooser: View {
	let isLoading: Bool
	let isFlashing: Bool
	let onBrowse: () -> Void
	let onRetry: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				Image(systemName: "arrow.down.circle.fill")
					.font(.title3)
					.foregroundStyle(Color.accentColor)
					.frame(width: 28)
				VStack(alignment: .leading, spacing: 3) {
					Text("Choose a transcription model")
						.font(.body.weight(.medium))
					Text("Download a local model to start transcribing.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Button("Browse Models…", action: onBrowse)
					.buttonStyle(.borderedProminent)
					.controlSize(.small)
			}

			if isLoading {
				ProgressView("Checking locally installed models…")
					.font(.caption)
			} else {
				Button("Refresh local model status", action: onRetry)
					.font(.caption)
					.buttonStyle(.link)
			}
		}
		.padding(10)
		.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(borderColor, lineWidth: isFlashing ? 3 : 1)
				.animation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true), value: isFlashing)
		)
	}

	private var borderColor: Color {
		if isFlashing { return Color.accentColor }
		return Color.primary.opacity(0.08)
	}

}

private struct CurrentModelSummary: View {
	let model: CuratedModelInfo?
	let selectedModelName: String?
	let isInstalled: Bool
	let isDownloadingAnything: Bool
	let downloadingModel: CuratedModelInfo?
	let downloadProgress: Double
	let onBrowse: () -> Void
	let onDownload: () -> Void
	let onCancelDownload: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: iconName)
				.font(.title3)
				.foregroundStyle(needsDownload ? Color.orange : Color.accentColor)
				.frame(width: 28)

			VStack(alignment: .leading, spacing: 5) {
				Text(title)
					.font(.body.weight(.medium))
				Text(subtitle)
					.font(.caption)
					.foregroundStyle(needsDownload ? Color.orange : Color.secondary)
				if let activeDownloadStatus {
					Text(activeDownloadStatus)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				if isDownloadingAnything {
					ProgressView(value: downloadProgress)
						.progressViewStyle(.linear)
				}
			}

			Spacer()

			if isDownloadingAnything {
				VStack(alignment: .trailing, spacing: 4) {
					Text("\(Int(downloadProgress * 100))%")
						.font(.caption)
						.foregroundStyle(.secondary)
						.monospacedDigit()
					Button("Cancel", role: .destructive, action: onCancelDownload)
						.controlSize(.small)
				}
			} else {
				HStack(spacing: 8) {
					if needsDownload {
						Button("Download", action: onDownload)
							.buttonStyle(.borderedProminent)
							.controlSize(.small)
					}
					Button("Browse Models…", action: onBrowse)
						.controlSize(.small)
				}
			}
		}
		.padding(10)
		.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
	}

	/// The selection references a model that isn't on disk (e.g. the scan came
	/// back empty after an update). Offer a direct download instead of
	/// pretending it's installed.
	private var needsDownload: Bool {
		selectedModelName != nil && !isInstalled && !isDownloadingAnything
	}

	private var title: String {
		if let model { return model.displayName }
		if let selectedModelName {
			return selectedModelName
				.replacingOccurrences(of: "-", with: " ")
				.replacingOccurrences(of: "_", with: " ")
				.capitalized
		}
		if let downloadingModel { return "Downloading \(downloadingModel.displayName)…" }
		return "Choose a transcription model"
	}

	private var subtitle: String {
		if needsDownload { return "Not downloaded — transcription won't work until you download it." }
		if let model { return "\(model.size) · \(model.storageSize)" }
		if selectedModelName != nil { return "Installed local model" }
		if let downloadingModel { return "\(downloadingModel.storageSize) will be stored locally on this Mac." }
		return "Download a local model to start transcribing."
	}

	private var activeDownloadStatus: String? {
		guard selectedModelName != nil, let downloadingModel else { return nil }
		return "Downloading \(downloadingModel.displayName)…"
	}

	private var iconName: String {
		if needsDownload { return "exclamationmark.triangle.fill" }
		if selectedModelName == nil { return "arrow.down.circle.fill" }
		return "waveform"
	}

}

private struct ModelLibrarySheet: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>
	@Environment(\.dismiss) private var dismiss
	@State private var pendingDelete: CuratedModelInfo?

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(alignment: .top) {
				VStack(alignment: .leading, spacing: 4) {
					Text("Model Library")
						.font(.title2.weight(.semibold))
					Text("Select an installed model to use it, or download another model for local transcription.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.defaultAction)
			}

			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					modelSection(title: "Available Models", models: Array(store.curatedModels))
				}
			}

			Label("Models run locally on your Mac. Downloads are stored on this device.", systemImage: "lock.shield")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(18)
		.frame(minWidth: 680, minHeight: 420)
		.confirmationDialog(
			"Remove \(pendingDelete?.displayName ?? "model")?",
			isPresented: Binding(
				get: { pendingDelete != nil },
				set: { if !$0 { pendingDelete = nil } }
			),
			titleVisibility: .visible
		) {
			if let pendingDelete {
				Button("Remove Download", role: .destructive) {
					store.send(.deleteModel(pendingDelete.internalName))
					self.pendingDelete = nil
				}
			}
			Button("Cancel", role: .cancel) { pendingDelete = nil }
		} message: {
			if let pendingDelete {
				Text("This frees \(pendingDelete.storageSize) on this Mac. You can download it again anytime.")
			}
		}
	}

	private func select(_ model: CuratedModelInfo) {
		guard model.isDownloaded, !store.isDownloading else { return }
		store.send(.selectModel(model.internalName))
	}

	@ViewBuilder
	private func modelSection(title: String, models: [CuratedModelInfo]) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
				.padding(.horizontal, 2)
			VStack(spacing: 0) {
				ForEach(models) { model in
					ModelLibraryRow(
						model: model,
						isSelected: model.isDownloaded && isSelected(model),
						isDownloading: isDownloading(model),
						// Only the active row receives live progress so the other
							// rows don't re-render on every tick.
							downloadProgress: isDownloading(model) ? store.downloadProgress : 0,
							isDisabled: store.isDownloading && !isDownloading(model),
							onSelect: { select(model) },
						onDownload: { store.send(.downloadModel(model.internalName)) },
						onCancelDownload: { store.send(.cancelDownload) },
						onShowInFinder: { store.send(.openModelLocation(model.internalName)) },
						onDelete: { pendingDelete = model }
					)
					if model.id != models.last?.id {
						Divider().padding(.leading, 54)
					}
				}
			}
			.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
		}
	}

	private func isSelected(_ model: CuratedModelInfo) -> Bool {
		let selected = store.hexSettings.selectedModel
		return modelNamesMatch(model.internalName, selected)
	}

	private func isDownloading(_ model: CuratedModelInfo) -> Bool {
		store.isDownloading && store.downloadingModelName == model.internalName
	}

}

private struct ModelLibraryRow: View {
	let model: CuratedModelInfo
	let isSelected: Bool
	let isDownloading: Bool
	let downloadProgress: Double
	let isDisabled: Bool
	let onSelect: () -> Void
	let onDownload: () -> Void
	let onCancelDownload: () -> Void
	let onShowInFinder: () -> Void
	let onDelete: () -> Void

	var body: some View {
		HStack(spacing: 0) {
			Button(action: onSelect) {
				HStack(spacing: 12) {
					Image(systemName: leadingIcon)
						.foregroundStyle(leadingColor)
						.font(.body)
						.frame(width: 24)

					VStack(alignment: .leading, spacing: 4) {
						HStack(spacing: 7) {
							Text(model.displayName)
								.font(.body.weight(.medium))
							if model.experimental {
								Text("Experimental")
									.font(.caption2.weight(.semibold))
									.padding(.horizontal, 5)
									.padding(.vertical, 2)
									.background(Color.orange.opacity(0.14), in: Capsule())
									.foregroundStyle(.orange)
							}
						}
						Text(model.size)
							.font(.caption)
							.foregroundStyle(.secondary)
						Text("\(model.backend.displayName) · \(model.precision) · \(model.license)")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(1)
					}

					Spacer()

					VStack(alignment: .trailing, spacing: 3) {
						Text(model.storageSize)
							.font(.caption)
							.foregroundStyle(.secondary)
						if let statusText {
							Text(statusText)
								.font(.caption2)
								.foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
						}
					}
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
				.contentShape(.rect)
			}
			.buttonStyle(.plain)

			trailingControls
				.padding(.trailing, 12)
		}
		.disabled(isDisabled)
		.opacity(isDisabled ? 0.55 : 1)
		.background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
		.help(modelDetails)
		.contextMenu {
			if isDownloading {
				Button("Cancel Download", role: .destructive, action: onCancelDownload)
				Button("Show in Finder", action: onShowInFinder)
			}
			if model.isDownloaded {
				managementMenuItems
			}
		}
	}

	/// Shared by the trailing ⋯ menu and the right-click context menu.
	@ViewBuilder
	private var managementMenuItems: some View {
		Button("Show in Finder", action: onShowInFinder)
		Divider()
		Button("Remove Download…", role: .destructive, action: onDelete)
	}

	@ViewBuilder
	private var trailingControls: some View {
		if isDownloading {
			HStack(spacing: 8) {
				ProgressView(value: downloadProgress)
					.progressViewStyle(.circular)
					.controlSize(.small)
				Text("\(Int(downloadProgress * 100))%")
					.font(.caption)
					.foregroundStyle(.secondary)
					.monospacedDigit()
				Button("Cancel", role: .destructive, action: onCancelDownload)
					.controlSize(.small)
			}
		} else if model.isDownloaded {
			Menu {
				managementMenuItems
			} label: {
				Image(systemName: "ellipsis.circle")
					.font(.body)
					.foregroundStyle(.secondary)
			}
			.menuStyle(.borderlessButton)
			.menuIndicator(.hidden)
			.fixedSize()
			.help("Show in Finder or remove this download")
		} else {
			Button("Download", action: onDownload)
				.controlSize(.small)
				.help("Download \(model.storageSize) and switch to this model")
		}
	}

	private var statusText: String? {
		if isDownloading { return "Downloading…" }
		if isSelected { return "In Use" }
		if model.isDownloaded { return "Installed" }
		return nil
	}

	private var leadingIcon: String {
		if isDownloading { return "arrow.down.circle.fill" }
		if isSelected { return "checkmark.circle.fill" }
		if model.isDownloaded { return "circle" }
		return "arrow.down.circle"
	}

	private var leadingColor: Color {
		if isDownloading || isSelected { return .accentColor }
		return .secondary
	}

	private var modelDetails: String {
		let revision = model.revision ?? "not pinned by this catalog entry"
		let capabilities = [
			model.capabilities.wordTimings ? "word timings" : "no word timings",
			model.capabilities.contextPrompt ? "terminology context" : "no terminology context",
			model.capabilities.languageHint ? "language hint" : "automatic/model-controlled language",
		].joined(separator: ", ")
		return "\(model.repository)\nRevision: \(revision)\nLanguages: \(model.languages.joined(separator: ", "))\nCapabilities: \(capabilities)"
	}

}
