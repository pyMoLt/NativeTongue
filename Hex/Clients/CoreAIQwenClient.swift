import CoreAIQwenASRVendored
import Foundation
import HexCore
import Hub

/// Qwen3-ASR 1.7B as a Core AI bundle (macOS 27 only, experimental).
///
/// mlboydaisuke/Qwen3-ASR-1.7B-CoreAI (gpu-pipelined: int8 decoder + fp16 AuT
/// encoder) through the vendored coreai-kit runtime. Measured in the dictation
/// pipeline (M5 Pro, 14 clips): same accuracy as the MLX checkpoint (10.3 % vs
/// 10.2 % WER) with 0.76 GB instead of 7.2 GB, about half as fast. The decoder
/// picks each token inside the graph, so punctuation cannot be masked: Literal
/// relies on the text normalizer and may lose spoken marks in fluent speech.
enum CoreAIQwenStore {
	static let modelName = "qwen3-asr-1.7b-coreai"
	static let repository = "mlboydaisuke/Qwen3-ASR-1.7B-CoreAI"
	static let revision = "11b7087289d5f7bd33d5c5cf79ba06044d0e3a51"
	static let decoderPath = "gpu-pipelined/qwen3_asr_1.7b_decode_int8hu_n390_s1"
	static let encoderPath = "gpu-pipelined/qwen3_asr_1.7b_audio_encoder_fp16_k30"
	/// The encoder reads at most 30 s; longer utterances are decoded in windows.
	static let windowSeconds = 30.0
	private static let manifestName = "local-asr-installation.json"

	private struct Manifest: Codable, Equatable {
		let repository: String
		let revision: String
		let bytes: UInt64
	}

	static var isSupported: Bool {
		if #available(macOS 27.0, *) { true } else { false }
	}

	static func downloadBase() throws -> URL {
		try URL.hexModelsDirectory.appendingPathComponent("coreai/qwen3-asr-1.7b", isDirectory: true)
	}

	static func modelDirectory() throws -> URL {
		repository.split(separator: "/").reduce(try downloadBase().appendingPathComponent("models", isDirectory: true)) {
			$0.appendingPathComponent(String($1), isDirectory: true)
		}
	}

	static func isInstalled() -> Bool {
		guard isSupported,
		      let directory = try? modelDirectory(),
		      let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
		      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
		      manifest.repository == repository, manifest.revision == revision
		else { return false }
		return directorySize(directory.appendingPathComponent("gpu-pipelined")) == manifest.bytes
	}

	/// Explicit install action only; pinned revision, size recorded for later checks.
	static func install(progress: @escaping (Progress) -> Void) async throws {
		guard isSupported else { throw unsupported() }
		if isInstalled() { return }
		let hub = HubApi(downloadBase: try downloadBase(), useOfflineMode: false)
		let directory = try await hub.snapshot(
			from: HubApi.Repo(id: repository), revision: revision,
			matching: ["\(decoderPath)/*", "\(encoderPath)/*"]
		) { value in
			let mapped = Progress(totalUnitCount: 100)
			mapped.completedUnitCount = Int64(value.fractionCompleted * 99)
			progress(mapped)
		}
		for path in [decoderPath, encoderPath] where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
			throw NSError(domain: "CoreAIQwen", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Qwen3-ASR (Core AI) download is incomplete."])
		}
		let manifest = Manifest(repository: repository, revision: revision, bytes: directorySize(directory.appendingPathComponent("gpu-pipelined")))
		try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(manifestName), options: .atomic)
		let done = Progress(totalUnitCount: 100)
		done.completedUnitCount = 100
		progress(done)
	}

	/// Removes the model and the Core AI specialization cache it created.
	static func delete() throws {
		let base = try downloadBase()
		if #available(macOS 27.0, *), let directory = try? modelDirectory() {
			for path in [decoderPath, encoderPath] {
				let url = directory.appendingPathComponent(path)
				if FileManager.default.fileExists(atPath: url.path) { _ = try? PreparedModel.clearCache(at: url) }
			}
		}
		if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
	}

	static func unsupported() -> NSError {
		NSError(domain: "CoreAIQwen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Qwen3-ASR (Core AI) needs macOS 27 or later."])
	}

	/// Qwen3-ASR names languages in its prompt ("German"); nil = auto-detect.
	static func languageName(_ code: String?) -> String? {
		guard let code = code?.lowercased(), !code.isEmpty else { return nil }
		let names = ["de": "German", "en": "English", "fr": "French", "es": "Spanish", "it": "Italian", "pt": "Portuguese",
		             "nl": "Dutch", "pl": "Polish", "ru": "Russian", "ja": "Japanese", "zh": "Chinese", "ko": "Korean"]
		return names[String(code.prefix(2))]
	}

	private static func directorySize(_ url: URL) -> UInt64 {
		guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
		var total: UInt64 = 0
		for case let file as URL in enumerator {
			total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		}
		return total
	}
}

@available(macOS 27.0, *)
actor CoreAIQwenEngine {
	static let shared = CoreAIQwenEngine()

	private var runtime: ASRRuntime?

	func load() async throws {
		guard runtime == nil else { return }
		guard CoreAIQwenStore.isInstalled() else {
			throw NSError(domain: "CoreAIQwen", code: 4, userInfo: [NSLocalizedDescriptionKey: "Qwen3-ASR (Core AI) is not installed. Install it under Models."])
		}
		let directory = try CoreAIQwenStore.modelDirectory()
		runtime = try await ASRRuntime(
			decoderBundleAt: directory.appendingPathComponent(CoreAIQwenStore.decoderPath),
			encoderModelAt: directory.appendingPathComponent(CoreAIQwenStore.encoderPath),
			arch: .qwen3ASR1_7B)
		HexLog.models.info("Loaded Qwen3-ASR 1.7B (Core AI)")
	}

	func unload() {
		runtime?.detach()
		runtime = nil
	}

	func transcribe(samples: [Float], language: String?) async throws -> String {
		try await load()
		guard let runtime else { return "" }
		let windowLength = Int(CoreAIQwenStore.windowSeconds * 16_000)
		var texts: [String] = []
		var start = 0
		while start < samples.count {
			try Task.checkCancellation()
			let end = Self.cut(samples, from: start, maxLength: windowLength)
			try await runtime.attach(samples: Array(samples[start ..< end]))
			let text = try await runtime.transcribe(language: CoreAIQwenStore.languageName(language)).text
			runtime.detach()
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty { texts.append(trimmed) }
			start = end
		}
		return texts.joined(separator: " ")
	}

	/// End of the next window: the quietest 100 ms in the window's last third.
	static func cut(_ samples: [Float], from start: Int, maxLength: Int) -> Int {
		guard samples.count - start > maxLength else { return samples.count }
		let hop = 1_600
		var best = start + maxLength
		var bestEnergy = Float.infinity
		var position = start + maxLength * 2 / 3
		while position + hop <= start + maxLength {
			var energy: Float = 0
			for index in position ..< position + hop { energy += samples[index] * samples[index] }
			if energy < bestEnergy { bestEnergy = energy; best = position + hop / 2 }
			position += hop / 2
		}
		return best
	}
}
