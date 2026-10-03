import Foundation
import HexCore

/// A language model for AI post-processing (bundled `llm-models.json` or a
/// Hugging Face link the user added).
struct LLMModelDescriptor: Codable, Equatable, Identifiable, Sendable {
  enum SizeClass: String, Codable, Sendable { case tiny, small, medium, large, custom }
  enum Speed: String, Codable, Sendable { case fastest, fast, medium, slow, unknown }
  enum UseCase: String, Codable, Sendable { case auto, box }

  let id: String
  let displayName: String
  let family: String
  let repository: String
  let revision: String
  let variant: String
  let downloadSize: String
  let license: String
  let sizeClass: SizeClass
  let speed: Speed
  let recommendedFor: [UseCase]
  let experimental: Bool
  let languages: [String]
  let blurb: String

  var isCustom: Bool { sizeClass == .custom }

  init(custom model: CustomLLMModel) {
    id = model.id
    displayName = model.repository.split(separator: "/").last.map(String.init) ?? model.repository
    family = "Hugging Face"
    repository = model.repository
    revision = model.revision
    variant = model.modelType ?? "unknown"
    downloadSize = ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
    license = model.license ?? "see model page"
    sizeClass = .custom
    speed = .unknown
    recommendedFor = []
    experimental = true
    languages = []
    blurb = "Added from a Hugging Face link. Not tested by NativeTongue — check the result before relying on it."
  }
}

enum LLMModelCatalog {
  /// Parsed once; the curated list is a bundled, immutable resource.
  static let bundled: [LLMModelDescriptor] = {
    guard let url = Bundle.main.url(forResource: "llm-models", withExtension: "json")
      ?? Bundle.main.url(forResource: "llm-models", withExtension: "json", subdirectory: "Data"),
      let data = try? Data(contentsOf: url)
    else { return [] }
    return (try? JSONDecoder().decode([LLMModelDescriptor].self, from: data)) ?? []
  }()

  static func all(settings: PostProcessingSettings) -> [LLMModelDescriptor] {
    bundled + settings.customModels.map(LLMModelDescriptor.init(custom:))
  }

  static func descriptor(id: String, settings: PostProcessingSettings) -> LLMModelDescriptor? {
    all(settings: settings).first { $0.id == id }
  }

  /// Suggested default for a use case (first catalog entry recommended for it).
  static func recommended(for useCase: LLMModelDescriptor.UseCase) -> LLMModelDescriptor? {
    bundled.first { $0.recommendedFor.contains(useCase) }
  }
}
