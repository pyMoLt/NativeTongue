import CoreAISpeechVendored
import CryptoKit
import Foundation
import HexCore
import Hub

/// Parakeet Ultra as a Core AI streaming bundle (macOS 27 only, experimental).
///
/// The bundle (maxffarrell/parakeet-ultra-coreai, Apple's export recipe) is a
/// *streaming* export with a 12-s traced window, so every transcription runs
/// through Apple's `CoreAISpeech` streaming session: batch dictation pushes the
/// whole utterance and collects the finalized segments, Streaming mode pushes
/// live audio. Measured (M5 Pro, 3 min audio): 0.23 GB peak, ≈ 40× real time,
/// same accuracy as the Core ML Parakeet Ultra.
enum CoreAIParakeetStore {
	static let modelName = "parakeet-ultra-coreai"
	static let repository = "maxffarrell/parakeet-ultra-coreai"
	static let revision = "c8d7dfb71248c128345d15e3cf5d8ba7c76ddac2"
	static let archiveName = "model.zip"
	static let archiveSHA256 = "a0059f4740eecb077a60fb99ff6de3bb90880aabb5c009e2b19c6d41d269f430"
	static let bundleName = "parakeet-ultra_float16_streaming150"
	private static let manifestName = "local-asr-installation.json"

	private struct Manifest: Codable, Equatable {
		let repository: String
		let revision: String
		let archiveSHA256: String
	}

	/// Core AI exists from macOS 27 on; the app itself still runs on macOS 26.
	static var isSupported: Bool {
		if #available(macOS 27.0, *) { true } else { false }
	}

	static func baseDirectory() throws -> URL {
		try URL.hexModelsDirectory.appendingPathComponent("coreai/parakeet-ultra", isDirectory: true)
	}

	static func bundleDirectory() throws -> URL {
		try baseDirectory().appendingPathComponent(bundleName, isDirectory: true)
	}

	static func isInstalled() -> Bool {
		guard isSupported,
		      let base = try? baseDirectory(),
		      let data = try? Data(contentsOf: base.appendingPathComponent(manifestName)),
		      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
		      manifest == Manifest(repository: repository, revision: revision, archiveSHA256: archiveSHA256),
		      let bundle = try? bundleDirectory()
		else { return false }
		return FileManager.default.fileExists(atPath: bundle.appendingPathComponent("metadata.json").path)
	}

	/// Explicit install action only: pinned revision, archive checked against its SHA-256.
	static func install(progress: @escaping (Progress) -> Void) async throws {
		guard isSupported else { throw unsupported() }
		if isInstalled() { return }
		let base = try baseDirectory()
		let downloads = base.appendingPathComponent("download", isDirectory: true)
		try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
		let hub = HubApi(downloadBase: downloads, useOfflineMode: false)
		let snapshot = try await hub.snapshot(from: HubApi.Repo(id: repository), revision: revision, matching: [archiveName]) { value in
			progress(fraction(value.fractionCompleted * 0.9))
		}
		let archive = snapshot.appendingPathComponent(archiveName)
		guard try sha256(of: archive) == archiveSHA256 else {
			try? FileManager.default.removeItem(at: downloads)
			throw NSError(domain: "CoreAIParakeet", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Parakeet Ultra (Core AI) download is damaged. Please try again."])
		}
		let unpacked = base.appendingPathComponent("unpacked", isDirectory: true)
		try? FileManager.default.removeItem(at: unpacked)
		let ditto = Process()
		ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
		ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
		try ditto.run()
		ditto.waitUntilExit()
		guard ditto.terminationStatus == 0 else {
			throw NSError(domain: "CoreAIParakeet", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not unpack Parakeet Ultra (Core AI)."])
		}
		let bundle = try bundleDirectory()
		try? FileManager.default.removeItem(at: bundle)
		try FileManager.default.moveItem(at: unpacked.appendingPathComponent(bundleName), to: bundle)
		try? FileManager.default.removeItem(at: unpacked)
		try? FileManager.default.removeItem(at: downloads)
		let manifest = Manifest(repository: repository, revision: revision, archiveSHA256: archiveSHA256)
		try JSONEncoder().encode(manifest).write(to: base.appendingPathComponent(manifestName), options: .atomic)
		progress(fraction(1))
	}

	/// Removes the bundle and the Core AI specialization cache it created
	/// (several GB under ~/Library/Caches/coreai-cache).
	static func delete() throws {
		let base = try baseDirectory()
		if #available(macOS 27.0, *), let bundle = try? bundleDirectory(), FileManager.default.fileExists(atPath: bundle.path) {
			_ = try? PreparedModel.clearCache(at: bundle)
		}
		if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
	}

	static func unsupported() -> NSError {
		NSError(domain: "CoreAIParakeet", code: 3, userInfo: [NSLocalizedDescriptionKey: "Parakeet Ultra (Core AI) needs macOS 27 or later."])
	}

	private static func fraction(_ value: Double) -> Progress {
		let progress = Progress(totalUnitCount: 100)
		progress.completedUnitCount = Int64(min(max(value, 0), 1) * 100)
		return progress
	}

	private static func sha256(of url: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher = SHA256()
		while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}
}

/// The loaded model and its streaming session. One instance serves batch
/// dictation and Streaming mode; only one ASR model is resident at a time.
@available(macOS 27.0, *)
actor CoreAIParakeetEngine {
	static let shared = CoreAIParakeetEngine()

	private var model: SpeechRecognitionModel?
	private var collector: Task<Void, Never>?
	private var finals: [String] = []
	/// Finalized segments with their time span (batch path).
	private var timedFinals: [(text: String, start: Double, end: Double)] = []
	private var partial = ""

	var isLoaded: Bool { model != nil }

	func load() async throws {
		guard model == nil else { return }
		guard CoreAIParakeetStore.isInstalled() else {
			throw NSError(domain: "CoreAIParakeet", code: 4, userInfo: [NSLocalizedDescriptionKey: "Parakeet Ultra (Core AI) is not installed. Install it under Models."])
		}
		model = try await SpeechRecognitionModel(resourcesAt: try CoreAIParakeetStore.bundleDirectory())
		HexLog.models.info("Loaded Parakeet Ultra (Core AI)")
	}

	func unload() {
		collector?.cancel()
		collector = nil
		model = nil
	}

	/// Batch: the whole recording through the streaming session (the bundle's
	/// offline path only sees its 12-s window). Segments carry only a time span,
	/// so each segment's words are spread over it in proportion to their length;
	/// the pipeline aligns them to the measured pauses like Whisper's words and
	/// the model keeps the full context (per-utterance decoding cost 4–6 points
	/// of WER in the pipeline test).
	func transcribe(samples: [Float]) async throws -> EngineResult {
		try await load()
		try await beginStream()
		try await append(samples)
		_ = try await endStream()
		var words: [EngineWord] = []
		for segment in timedFinals {
			let pieces = segment.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
			let total = Double(max(1, pieces.reduce(0) { $0 + $1.count + 1 }))
			let span = max(segment.end - segment.start, 0.01)
			var cursor = segment.start
			for piece in pieces {
				let length = span * Double(piece.count + 1) / total
				words.append(EngineWord(text: piece, start: cursor, end: cursor + length * 0.9))
				cursor += length
			}
		}
		timedFinals = []
		return EngineResult(text: words.map(\.text).joined(separator: " "), words: words)
	}

	// MARK: Streaming session

	/// Batch keeps Apple's endpointing (0.8 s silence, 30-s segments: best accuracy in the
	/// pipeline test). Streaming closes a segment after 0.4 s and at most every 10 s so text
	/// is committed sooner (first committed text after 14.5 s instead of 38.5 s of audio).
	static let liveEndpointing = EndpointingConfig(silenceFrames: 5, maxSegmentFrames: 125, resetAfterSilenceFrames: 40)

	func beginStream(endpointing: EndpointingConfig = EndpointingConfig()) async throws {
		try await load()
		guard let model else { return }
		collector?.cancel()
		finals = []
		timedFinals = []
		partial = ""
		let updates = try await model.startStream(endpointing: endpointing, deferredDecode: false)
		collector = Task { [weak self] in
			do {
				for try await update in updates {
					await self?.receive(update)
				}
			} catch {
				HexLog.models.error("Core AI Parakeet stream failed: \(error.localizedDescription, privacy: .private)")
			}
		}
	}

	/// Pushes audio in chunk-sized slices, as a host tap would.
	func append(_ samples: [Float]) async throws {
		guard let model else { return }
		let push = await model.activeStreamingConfig.map { $0.chunkFrames * $0.samplesPerEncoderFrame } ?? 16_000
		var offset = 0
		while offset < samples.count {
			let end = min(offset + max(push, 1), samples.count)
			try await model.append(pcm: Array(samples[offset ..< end]))
			offset = end
		}
	}

	/// Finalized segments since the last call, plus the volatile tail.
	func drain() -> (finals: [String], partial: String) {
		defer { finals = [] }
		return (finals, partial)
	}

	func endStream() async throws -> [String] {
		guard let model else { return [] }
		_ = try await model.finishStream()
		await collector?.value
		collector = nil
		partial = ""
		defer { finals = [] }
		return finals
	}

	private func receive(_ update: TranscriptionUpdate) {
		switch update {
		case let .partial(segment):
			partial = segment.text
		case let .finalized(segment):
			let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
			if !text.isEmpty {
				finals.append(text)
				timedFinals.append((text, segment.startTime, segment.endTime))
			}
			partial = ""
		}
	}
}

/// Streaming mode on Parakeet Ultra (Core AI): live text from the bundle's
/// cache-aware streaming session. Finalized segments are typed, the open
/// segment is shown as pending text.
@available(macOS 27.0, *)
actor CoreAIParakeetStreamingEngine: StreamingEngine {
	private let engine = CoreAIParakeetEngine.shared

	func load() async throws {
		try await engine.load()
	}

	func begin(language: String?) async throws {
		try await engine.beginStream(endpointing: CoreAIParakeetEngine.liveEndpointing)
	}

	func feed(_ samples: [Float]) async throws -> StreamingUpdate {
		try await engine.append(samples)
		let (finals, partial) = await engine.drain()
		return StreamingUpdate(committed: finals.joined(separator: " "), pending: partial, startsSegment: !finals.isEmpty)
	}

	func end() async throws -> StreamingUpdate {
		let finals = try await engine.endStream()
		return StreamingUpdate(committed: finals.joined(separator: " "), startsSegment: !finals.isEmpty)
	}

	func unload() async {
		await engine.unload()
	}
}
