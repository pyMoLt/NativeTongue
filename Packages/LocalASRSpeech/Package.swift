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
    .library(name: "Qwen3ASR", targets: ["Qwen3ASR", "LocalLLM", "VoxtralRealtime"]),
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
