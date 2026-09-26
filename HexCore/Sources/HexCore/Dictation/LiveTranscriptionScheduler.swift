import Foundation

public enum LiveTranscriptionEvent: Sendable, Equatable {
	case utteranceTranscribed(AlignedUtterance)
	case pauseAfterKnown(id: Int, milliseconds: Int)
}

/// Serially transcribes each pause-closed utterance from the bounded live-audio assembler.
/// The caller owns the stream and keeps its full WAV as the final-accuracy fallback.
public actor LiveTranscriptionScheduler {
	private var assembler: LiveUtteranceAssembler
	private var isProcessing = false
	private var processingWaiters: [CheckedContinuation<Void, Never>] = []

	public init(config: SegmenterConfig = SegmenterConfig()) {
		assembler = LiveUtteranceAssembler(config: config)
	}

	public func append(
		_ chunk: AudioChunk,
		transcribe: @Sendable ([Float]) async throws -> EngineResult
	) async throws -> [LiveTranscriptionEvent] {
		await acquireProcessingTurn()
		defer { releaseProcessingTurn() }
		return try await process(assembler.append(chunk), transcribe: transcribe)
	}

	public func finish(
		transcribe: @Sendable ([Float]) async throws -> EngineResult
	) async throws -> [LiveTranscriptionEvent] {
		await acquireProcessingTurn()
		defer { releaseProcessingTurn() }
		return try await process(assembler.finish(), transcribe: transcribe)
	}

	private func acquireProcessingTurn() async {
		guard isProcessing else {
			isProcessing = true
			return
		}
		await withCheckedContinuation { continuation in
			processingWaiters.append(continuation)
		}
	}

	private func releaseProcessingTurn() {
		guard !processingWaiters.isEmpty else {
			isProcessing = false
			return
		}
		processingWaiters.removeFirst().resume()
	}

	private func process(
		_ events: [LiveUtteranceEvent],
		transcribe: @Sendable ([Float]) async throws -> EngineResult
	) async throws -> [LiveTranscriptionEvent] {
		var output: [LiveTranscriptionEvent] = []
		for event in events {
			switch event {
			case let .utteranceReady(utterance, samples):
				let result = try await transcribe(samples)
				output.append(.utteranceTranscribed(AlignedUtterance(
					utterance: utterance,
					text: result.text,
					language: result.detectedLanguage
				)))
			case let .pauseAfterKnown(id, milliseconds):
				output.append(.pauseAfterKnown(id: id, milliseconds: milliseconds))
			}
		}
		return output
	}
}
