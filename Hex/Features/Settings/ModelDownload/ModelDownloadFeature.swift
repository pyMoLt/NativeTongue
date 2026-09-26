// MARK: – ModelDownloadFeature.swift

// A full‐featured TCA reducer for managing on‑device ML models.
// Dependencies: ComposableArchitecture, IdentifiedCollections, Dependencies

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import IdentifiedCollections

// ──────────────────────────────────────────────────────────────────────────

// MARK: – Data Models

// ──────────────────────────────────────────────────────────────────────────

public struct ModelInfo: Equatable, Identifiable {
	public let name: String
	public var isDownloaded: Bool

	public var id: String { name }
	public init(name: String, isDownloaded: Bool) {
		self.name = name
		self.isDownloaded = isDownloaded
	}
}

public struct CuratedModelInfo: Equatable, Identifiable, Codable {
	public let displayName: String
	public let internalName: String
	public let backend: LocalASRBackend
	public let repository: String
	public let revision: String?
	public let precision: String
	public let license: String
	public let languages: [String]
	public let size: String
	public let storageSize: String
	public let capabilities: LocalASRModelCapabilities
	public let experimental: Bool
	public var isDownloaded: Bool
	public var id: String { internalName }

	public init(
		displayName: String,
		internalName: String,
		backend: LocalASRBackend,
		repository: String,
		revision: String? = nil,
		precision: String,
		license: String,
		languages: [String],
		size: String,
		storageSize: String,
		capabilities: LocalASRModelCapabilities,
		experimental: Bool,
		isDownloaded: Bool
	) {
		self.displayName = displayName
		self.internalName = internalName
		self.backend = backend
		self.repository = repository
		self.revision = revision
		self.precision = precision
		self.license = license
		self.languages = languages
		self.size = size
		self.storageSize = storageSize
		self.capabilities = capabilities
		self.experimental = experimental
		self.isDownloaded = isDownloaded
	}

	// Codable (isDownloaded is set at runtime)
	private enum CodingKeys: String, CodingKey {
		case displayName, internalName, backend, repository, revision, precision, license
		case languages, size, storageSize, capabilities, experimental
	}
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		displayName = try c.decode(String.self, forKey: .displayName)
		internalName = try c.decode(String.self, forKey: .internalName)
		backend = try c.decode(LocalASRBackend.self, forKey: .backend)
		repository = try c.decode(String.self, forKey: .repository)
		revision = try c.decodeIfPresent(String.self, forKey: .revision)
		precision = try c.decode(String.self, forKey: .precision)
		license = try c.decode(String.self, forKey: .license)
		languages = try c.decode([String].self, forKey: .languages)
		size = try c.decode(String.self, forKey: .size)
		storageSize = try c.decode(String.self, forKey: .storageSize)
		capabilities = try c.decode(LocalASRModelCapabilities.self, forKey: .capabilities)
		experimental = try c.decode(Bool.self, forKey: .experimental)
		isDownloaded = false
	}
}

// Convenience helper for loading the bundled models.json once.
private enum CuratedModelLoader {
	private static let bundledModels: [CuratedModelInfo] = {
		guard let url = Bundle.main.url(forResource: "models", withExtension: "json") ??
			Bundle.main.url(forResource: "models", withExtension: "json", subdirectory: "Data")
		else {
			assertionFailure("models.json not found in bundle")
			return []
		}
		do { return try JSONDecoder().decode([CuratedModelInfo].self, from: Data(contentsOf: url)) }
		catch { assertionFailure("Failed to decode models.json - \(error)"); return [] }
	}()

	static func load() -> [CuratedModelInfo] {
		bundledModels
	}
}

// ──────────────────────────────────────────────────────────────────────────

// MARK: – Domain

// ──────────────────────────────────────────────────────────────────────────

@Reducer
public struct ModelDownloadFeature {
	@ObservableState
	public struct State: Equatable {
		// Shared user settings
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

		// Data derived from the local, bundled model catalog and on-disk checks
		public var availableModels: IdentifiedArrayOf<ModelInfo> = []
		public var curatedModels = IdentifiedArrayOf(uniqueElements: CuratedModelLoader.load())

		// UI state
		public var isLoadingModels = false
		public var isDownloading = false
		public var downloadProgress: Double = 0
		public var downloadError: String?
		public var downloadingModelName: String?

		// Track which model generated a progress update to handle switching models
		public var activeDownloadID: UUID?

		// Convenience computed vars
		var selectedModel: String { hexSettings.selectedModel }

		/// The downloaded model matching the current selection, pattern-aware so
		/// legacy or glob-style selections (e.g. "distil*large-v3") still resolve.
		private var downloadedModelMatchingSelection: ModelInfo? {
			guard !selectedModel.isEmpty else { return nil }
			return availableModels.first { model in
				model.isDownloaded && ModelPatternMatcher.namesMatch(model.name, selectedModel)
			}
		}

		var selectedModelNameForDisplay: String? {
			guard !selectedModel.isEmpty else { return nil }
			if let downloaded = downloadedModelMatchingSelection {
				return downloaded.name
			}
			if modelBootstrapState.isModelReady,
			   let identifier = modelBootstrapState.modelIdentifier,
			   ModelPatternMatcher.namesMatch(identifier, selectedModel)
			{
				return selectedModel
			}
			return hexSettings.hasCompletedModelBootstrap ? selectedModel : nil
		}

		var selectedModelIsDownloaded: Bool {
			downloadedModelMatchingSelection != nil
		}

		var anyModelDownloaded: Bool {
			availableModels.contains(where: { $0.isDownloaded })
		}
	}

	// MARK: Actions

	public enum Action: BindableAction {
		case binding(BindingAction<State>)
		// Requests
		case fetchModels
		case selectModel(String)
		case downloadModel(String)
		// Effects
		case modelsLoaded(available: [ModelInfo])
		case modelsLoadFailed
		case downloadProgress(id: UUID, progress: Double)
		case downloadCompleted(id: UUID, result: Result<String, Error>)
		case cancelDownload

		case deleteModel(String)
		case modelDeleted(String)
		case modelDeletionFailed(Error)
		case openModelLocation(String)
	}

	// MARK: Dependencies

	@Dependency(\.transcription) var transcription

	public init() {}

	// MARK: Reducer

	public var body: some ReducerOf<Self> {
		BindingReducer()
		Reduce(reduce)
	}

	// MARK: - Helpers (pattern matching)

	private func resolvePattern(_ pattern: String, from available: [ModelInfo]) -> String? {
		ModelPatternMatcher.resolvePattern(pattern, from: available.map { ($0.name, $0.isDownloaded) })
	}

	private func curatedDisplayName(for model: String, curated: IdentifiedArrayOf<CuratedModelInfo>) -> String {
		if let match = curated.first(where: { ModelPatternMatcher.matches($0.internalName, model) }) {
			return match.displayName
		}
		return model
			.replacingOccurrences(of: "-", with: " ")
			.replacingOccurrences(of: "_", with: " ")
			.capitalized
	}

	private func updateBootstrapState(_ state: inout State) {
		let model = state.hexSettings.selectedModel
		guard !model.isEmpty else {
			state.$modelBootstrapState.withLock { bootstrap in
				bootstrap.modelIdentifier = ""
				bootstrap.modelDisplayName = ""
				bootstrap.isModelReady = false
				bootstrap.progress = 0
				bootstrap.lastError = nil
			}
			return
		}
		let displayName = curatedDisplayName(for: model, curated: state.curatedModels)
		let isDownloaded = state.selectedModelIsDownloaded
		state.$modelBootstrapState.withLock { bootstrap in
			bootstrap.modelIdentifier = model
			bootstrap.modelDisplayName = displayName
			bootstrap.isModelReady = isDownloaded
			if isDownloaded {
				bootstrap.lastError = nil
				bootstrap.progress = 1
			}
		}
	}

	private func reduce(state: inout State, action: Action) -> Effect<Action> {
		switch action {
		// MARK: – UI bindings

		case .binding:
			return .none

		case let .selectModel(model):
			// If the curated item is a glob (e.g., "distil*large-v3"),
			// resolve it to a concrete available model so both tabs stay in sync
			let resolved = resolvePattern(model, from: Array(state.availableModels)) ?? model
			state.$hexSettings.withLock {
				$0.selectedModel = resolved
				$0.profileModelSelections[$0.asrProfile] = resolved
			}
			updateBootstrapState(&state)
			return .none

		// MARK: – Fetch Models

		case .fetchModels:
			guard !state.isLoadingModels else { return .none }
			state.isLoadingModels = true
			return .run { send in
				do {
					async let availableNamesTask = transcription.getAvailableModels()
					let names = try await availableNamesTask
					let infos = try await withThrowingTaskGroup(of: ModelInfo.self) { group -> [ModelInfo] in
						for name in names {
							group.addTask {
								ModelInfo(
									name: name,
									isDownloaded: await transcription.isModelDownloaded(name)
								)
							}
						}
						return try await group.reduce(into: []) { $0.append($1) }
					}
					await send(.modelsLoaded(available: infos))
				} catch {
					await send(.modelsLoadFailed)
				}
			}

		case .modelsLoadFailed:
			state.isLoadingModels = false
			return .none

		case let .modelsLoaded(available):
			state.isLoadingModels = false
			// Ensure every bundled Parakeet option is represented in the local model state.
			var availablePlus = available
			for model in ParakeetModel.allCases.reversed() {
				if !availablePlus.contains(where: { $0.name == model.identifier }) {
					availablePlus.insert(ModelInfo(name: model.identifier, isDownloaded: false), at: 0)
				}
			}

			state.availableModels = IdentifiedArrayOf(uniqueElements: availablePlus)

			// If the selected model is a pattern, resolve it now to the first available match
			if state.hexSettings.selectedModel.contains("*") || state.hexSettings.selectedModel.contains("?") {
				if let resolved = resolvePattern(state.hexSettings.selectedModel, from: available) {
					state.$hexSettings.withLock {
						$0.selectedModel = resolved
						$0.profileModelSelections[$0.asrProfile] = resolved
					}
				}
			}

			// Merge curated + download status with pattern support
			var curated = CuratedModelLoader.load()
			for idx in curated.indices {
				let internalName = curated[idx].internalName
				if let match = available.first(where: { ModelPatternMatcher.matches(internalName, $0.name) }) {
					curated[idx].isDownloaded = match.isDownloaded
				} else {
					curated[idx].isDownloaded = false
				}
			}
			state.curatedModels = IdentifiedArrayOf(uniqueElements: curated)
			// Never silently substitute a different model when the selected one is missing.
			updateBootstrapState(&state)
			return .none

		// MARK: – Download

		case let .downloadModel(requestedModel):
			guard !requestedModel.isEmpty, !state.isDownloading else { return .none }
			// Resolve glob/legacy selections to a concrete model name up front so
			// the completion handler updates the matching rows and writes a
			// concrete name back into settings.
			let model = resolvePattern(requestedModel, from: Array(state.availableModels)) ?? requestedModel
			state.downloadError = nil
			state.isDownloading = true
			state.downloadProgress = 0
			state.downloadingModelName = model
			state.activeDownloadID = UUID()
			let downloadID = state.activeDownloadID!
			if !state.anyModelDownloaded {
				let displayName = curatedDisplayName(for: model, curated: state.curatedModels)
				state.$modelBootstrapState.withLock {
					$0.modelIdentifier = model
					$0.modelDisplayName = displayName
					$0.isModelReady = false
					$0.progress = 0
					$0.lastError = nil
				}
			}
			return .run { send in
				do {
					try await transcription.downloadModel(model) { progress in
						let fractionCompleted = progress.fractionCompleted
						Task {
							await send(.downloadProgress(id: downloadID, progress: fractionCompleted))
						}
					}
					await send(.downloadCompleted(id: downloadID, result: .success(model)))
				} catch is CancellationError {
				} catch {
					await send(.downloadCompleted(id: downloadID, result: .failure(error)))
				}
			}
			.cancellable(id: downloadID)

		case let .downloadProgress(id, progress):
			guard state.activeDownloadID == id else { return .none }
			guard state.downloadProgress != progress else { return .none }
			state.downloadProgress = progress
			if !state.modelBootstrapState.isModelReady {
				state.$modelBootstrapState.withLock { $0.progress = progress }
			}
			return .none

		case let .downloadCompleted(id, result):
			guard state.activeDownloadID == id else { return .none }
			state.isDownloading = false
			state.downloadingModelName = nil
			state.activeDownloadID = nil
			state.downloadProgress = 0
			var failureMessage: String?
			switch result {
			case let .success(name):
				state.availableModels[id: name]?.isDownloaded = true
				if let idx = state.curatedModels.firstIndex(where: { $0.internalName == name }) {
					state.curatedModels[idx].isDownloaded = true
				}
				state.$hexSettings.withLock { settings in
					settings.selectedModel = name
					settings.profileModelSelections[settings.asrProfile] = name
					settings.hasCompletedModelBootstrap = true
				}
				state.downloadError = nil
			case let .failure(err):
				let ns = err as NSError
				var message = ns.localizedDescription
				if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
				   let host = url.host
				{
					message += " (\(host))"
				} else if let str = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
				          let u = URL(string: str), let host = u.host
				{
					message += " (\(host))"
				}
				state.downloadError = message
				failureMessage = message
			}
			state.$modelBootstrapState.withLock { bootstrap in
				if let failureMessage {
					bootstrap.isModelReady = false
					bootstrap.lastError = failureMessage
					bootstrap.progress = 0
				} else {
					bootstrap.isModelReady = true
					bootstrap.lastError = nil
					bootstrap.progress = 1
				}
			}
			updateBootstrapState(&state)
			return .none

		case .cancelDownload:
			guard let id = state.activeDownloadID else { return .none }
			state.isDownloading = false
			state.downloadingModelName = nil
			state.activeDownloadID = nil
			state.downloadProgress = 0
			state.$modelBootstrapState.withLock { $0.progress = 0 }
			updateBootstrapState(&state)
			return .cancel(id: id)

		case let .deleteModel(model):
			guard !model.isEmpty else { return .none }
			let resolved = resolvePattern(model, from: Array(state.availableModels)) ?? model
			if ModelPatternMatcher.namesMatch(model, state.selectedModel) {
				state.$modelBootstrapState.withLock { $0.isModelReady = false }
			}
			return .run { send in
				do {
					try await transcription.deleteModel(resolved)
					await send(.modelDeleted(resolved))
				} catch {
					await send(.modelDeletionFailed(error))
				}
			}

		case let .modelDeleted(model):
			state.availableModels[id: model]?.isDownloaded = false
			for index in state.curatedModels.indices
			where ModelPatternMatcher.matches(state.curatedModels[index].internalName, model) {
				state.curatedModels[index].isDownloaded = false
			}
			if ModelPatternMatcher.namesMatch(state.selectedModel, model) {
				let fallback = state.availableModels.first { $0.isDownloaded }?.name ?? ""
				state.$hexSettings.withLock {
					$0.selectedModel = fallback
					$0.profileModelSelections[$0.asrProfile] = fallback
				}
				updateBootstrapState(&state)
			}
			return .send(.fetchModels)

		case let .modelDeletionFailed(error):
			state.downloadError = error.localizedDescription
			updateBootstrapState(&state)
			return .none

		case let .openModelLocation(model):
			return openModelLocationEffect(for: model)
		}
	}

	// MARK: Helpers

	private func openModelLocationEffect(for model: String) -> Effect<Action> {
		// Parakeet caches live under FluidAudio's directory, not the WhisperKit
		// models folder. Route "Show in Finder" to the matching root so users
		// don't end up staring at an empty WhisperKit folder thinking the
		// Parakeet download silently failed.
		let backend = try? LocalASRModelCatalog.descriptor(named: model).backend
		return .run { _ in
			let base: URL
			switch backend {
			case .parakeetFluidAudioCoreML:
				base = try URL.hexParakeetModelsDirectory
			case .qwen3MLX:
				base = try URL.hexModelsDirectory.appendingPathComponent("qwen3-mlx", isDirectory: true)
			default:
				base = try URL.hexModelsDirectory
			}
			NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: base.path)
		}
	}
}
