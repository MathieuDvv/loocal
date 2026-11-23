// swift-tools-version: 6.2
// Vendored StableDiffusion from mlx-swift-examples (MIT, ml-explore) at ef1084dd. Changes:
// an optional float16 image decoder (LoadConfiguration.decoderFloat16);
// reads a model from a local folder (Loocal downloads it) instead of Hugging Face's client,
// prefers .fp16 weight files, and builds against the mlx-swift the app already pins.
import PackageDescription

let package = Package(
  name: "StableDiffusion",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "StableDiffusion", targets: ["StableDiffusion"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
  ],
  targets: [
    .target(
      name: "StableDiffusion",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXRandom", package: "mlx-swift"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
