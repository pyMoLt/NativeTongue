// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "LocalASRSpeech",
  platforms: [
    .macOS("15.0"),
  ],
  products: [
    .library(name: "Qwen3ASR", targets: ["Qwen3ASR"]),
    .library(name: "AudioCommon", targets: ["AudioCommon"]),
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
  ]
)
