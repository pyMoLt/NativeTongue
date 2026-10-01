import Foundation

/// Measurements from one local speaker, bundled for honest model comparisons.
/// An absent row means the model has not been measured in this corpus.
struct ModelBenchmarkCatalog: Decodable {
	let measuredAt: String
	let source: String
	let speakerCount: Int
	let terminologyReferenceCount: Int
	let literalCommandReferenceCount: Int
	let terminologyAudioSeconds: Int
	let memoryMetric: String
	let measurements: [ModelBenchmarkMeasurement]

	static func load(bundle: Bundle = .main) throws -> Self {
		guard let url = bundle.url(forResource: "model-benchmarks", withExtension: "json") ??
			bundle.url(forResource: "model-benchmarks", withExtension: "json", subdirectory: "Data")
		else {
			throw NSError(domain: "ModelBenchmarkCatalog", code: 1, userInfo: [
				NSLocalizedDescriptionKey: "The bundled model benchmark catalog is missing.",
			])
		}
		return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
	}

	func measurement(for internalName: String, configuration: ModelBenchmarkMeasurement.Configuration) -> ModelBenchmarkMeasurement? {
		measurements.first { $0.internalName == internalName && $0.configuration == configuration }
	}
}

struct ModelBenchmarkMeasurement: Decodable {
	enum Configuration: String, Decodable {
		case natural
		case punctuationSuppressed
	}

	let internalName: String
	let configuration: Configuration
	let literalCommandsRecognized: Int
	let automaticPunctuationCount: Int
	let terminologyCorrect: Int
	let medicalTermsCorrect: Int
	let technicalTermsCorrect: Int
	let wordErrorRatePercent: Double
	let peakProcessRSSGB: Double
	let transcriptionSeconds: Double
}
