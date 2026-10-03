import AVFoundation
import Foundation
import HexCore
import Speech

/// Apple's on-device `SpeechAnalyzer` + `DictationTranscriber` (macOS 26+).
/// Assets are managed by the system and installed only through the explicit
/// model-install action. Punctuation can be switched off natively for literal mode.
actor AppleSpeechASRClient {
	static let modelName = "apple-speechanalyzer-dictation"
	private let logger = HexLog.transcription

	static func locale(for language: String?) -> Locale {
		language?.lowercased().hasPrefix("en") == true ? Locale(identifier: "en-US") : Locale(identifier: "de-DE")
	}

	private func transcriber(language: String?, punctuation: Bool) -> DictationTranscriber {
		DictationTranscriber(
			locale: Self.locale(for: language),
			contentHints: [],
			transcriptionOptions: punctuation ? [.punctuation] : [],
			reportingOptions: [],
			attributeOptions: [.audioTimeRange, .transcriptionConfidence]
		)
	}

	func isInstalled() async -> Bool {
		for language in ["de", "en"] {
			let status = await AssetInventory.status(forModules: [transcriber(language: language, punctuation: true)])
			if status != .installed { return false }
		}
		return true
	}

	/// Explicit install action only (system download of the on-device speech assets).
	func install(progress: @escaping (Progress) -> Void) async throws {
		for language in ["de", "en"] {
			let module = transcriber(language: language, punctuation: true)
			guard await AssetInventory.status(forModules: [module]) != .unsupported else {
				throw NSError(domain: "AppleSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple speech recognition does not support \(language) on this Mac."])
			}
			if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
				progress(request.progress)
				try await request.downloadAndInstall()
			}
		}
		let done = Progress(totalUnitCount: 100)
		done.completedUnitCount = 100
		progress(done)
	}

	func transcribe(samples: [Float], options: RequestOptions) async throws -> EngineResult {
		guard !samples.isEmpty else { return EngineResult(text: "") }
		let module = transcriber(language: options.language, punctuation: options.punctuation == .natural)
		guard await AssetInventory.status(forModules: [module]) == .installed else {
			throw NSError(domain: "AppleSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple speech assets are not installed. Install the model first."])
		}
		let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
			?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
		let buffer = try Self.buffer(from: samples, format: format)

		let context = AnalysisContext()
		if !options.biasTerms.isEmpty {
			context.contextualStrings[.general] = Array(options.biasTerms.prefix(100))
		}
		let analyzer = SpeechAnalyzer(modules: [module])
		try await analyzer.setContext(context)
		try await analyzer.prepareToAnalyze(in: format)

		let collector = Task { () -> [DictationTranscriber.Result] in
			var results: [DictationTranscriber.Result] = []
			for try await result in module.results where result.isFinal {
				results.append(result)
			}
			return results
		}
		let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
		continuation.yield(AnalyzerInput(buffer: buffer))
		continuation.finish()
		try await analyzer.start(inputSequence: stream)
		try await analyzer.finalizeAndFinishThroughEndOfInput()
		let results = try await collector.value

		var text = ""
		var words: [EngineWord] = []
		for result in results {
			let piece = String(result.text.characters).trimmingCharacters(in: .whitespaces)
			guard !piece.isEmpty else { continue }
			text += text.isEmpty ? piece : " " + piece
			for run in result.text.runs {
				let runText = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
				guard !runText.isEmpty, let range = run.audioTimeRange else { continue }
				words.append(EngineWord(
					text: runText,
					start: range.start.seconds,
					end: range.end.seconds,
					confidence: run.transcriptionConfidence.map(Float.init)
				))
			}
		}
		return EngineResult(
			text: text,
			words: words,
			detectedLanguage: options.language,
			punctuationWasSuppressed: options.punctuation == .suppressed
		)
	}

	static func buffer(from samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
		let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
		let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))!
		input.frameLength = AVAudioFrameCount(samples.count)
		samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
		if format == source { return input }
		guard let converter = AVAudioConverter(from: source, to: format) else {
			throw NSError(domain: "AppleSpeech", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format for Apple speech recognition."])
		}
		let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16_000) + 1_024
		let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
		var consumed = false
		var error: NSError?
		converter.convert(to: output, error: &error) { _, status in
			if consumed { status.pointee = .endOfStream; return nil }
			consumed = true
			status.pointee = .haveData
			return input
		}
		if let error { throw error }
		return output
	}
}
