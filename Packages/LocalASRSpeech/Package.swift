// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "LocalASRSpeech",
  platforms: [
    .macOS("26.0"),
  ],
  products: [
    // LocalLLM rides on an already linked product so the Xcode project needs no
    // new package product reference.
    .library(name: "Qwen3ASR", targets: ["Qwen3ASR", "LocalLLM", "VoxtralRealtime", "CoreAISpeechVendored", "CoreAIQwenASRVendored"]),
    .library(name: "AudioCommon", targets: ["AudioCommon"]),
    .library(name: "CohereTranscribeASR", targets: ["CohereTranscribeASR"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/ml-explore/mlx-swift",
      exact: "0.31.4"
    ),
    .package(
      url: "https://github.com/huggingface/swift-transformers",
      exact: "1.1.6"
    ),
    // 3.31.4 is the release built against mlx-swift 0.31.4 (V2.5 research R1).
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      exact: "3.31.4"
    ),
  ],
  targets: [
    // Qwen3-ASR on Core AI: the language-model engine of john-rocky/coreai-models 0.2.4-zoo
    // (BSD-3-Clause, fork of apple/coreai-models; guided generation removed) and the Qwen3-ASR
    // runtime of mattt/coreai-kit (BSD-3-Clause). Marked macOS 27+, CoreAI weak-linked.
    .target(
      name: "CoreAIQwenASRVendored",
      dependencies: [
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "Hub", package: "swift-transformers"),
        .product(name: "Transformers", package: "swift-transformers"),
      ],
      exclude: ["LICENSE-coreai-models-zoo.txt", "LICENSE-coreai-kit.txt"],
      resources: [.copy("Kit/Resources/mel_filters.f32")],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .unsafeFlags(["-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "CoreAI"]),
      ],
      linkerSettings: [
        .unsafeFlags(["-weak_framework", "CoreAI"]),
      ]
    ),
    // Apple's CoreAISpeech (apple/coreai-models, BSD-3-Clause, see LICENSE-coreai-models.txt),
    // vendored with every declaration marked macOS 27+. The app keeps macOS 26 as its base:
    // CoreAI is weak-linked and only touched behind #available(macOS 27, *).
    .target(
      name: "CoreAISpeechVendored",
      dependencies: [
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      exclude: ["LICENSE-coreai-models.txt"],
      swiftSettings: [
        .unsafeFlags(["-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "CoreAI"]),
      ],
      linkerSettings: [
        .unsafeFlags(["-weak_framework", "CoreAI"]),
      ]
    ),
    .target(
      name: "AudioCommon",
      dependencies: [
        .product(name: "Hub", package: "swift-transformers"),
      ]
    ),
    .target(
      name: "MLXCommon",
      dependencies: [
        "AudioCommon",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "MLXFFT", package: "mlx-swift"),
      ]
    ),
    .target(
      name: "Qwen3ASR",
      dependencies: [
        "AudioCommon",
        "MLXCommon",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
      ]
    ),
    .target(
      name: "LocalLLM",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Hub", package: "swift-transformers"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ]
    ),
    // Vendored streaming path of Blaizzy/mlx-audio-swift (MIT), see THIRD_PARTY.md.
    .target(
      name: "VoxtralRealtime",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
      ]
    ),
    .target(
      name: "CohereTranscribeASR",
      dependencies: [
        "AudioCommon",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "MLXFFT", package: "mlx-swift"),
      ]
    ),
  ]
)
