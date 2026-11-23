// swift-tools-version: 6.2
// Vendored KokoroSwift 1.0.10 (MIT, Lassi Maksimainen) and MisakiSwift 1.0.5 (Apache 2.0),
// unchanged except for packaging: upstream ships them as dynamic frameworks, which made the
// app carry two copies of MLX. Built statically here, everything links once.
import PackageDescription

let package = Package(
  name: "KokoroSwift",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "KokoroSwift", targets: ["KokoroSwift"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
  ],
  targets: [
    .target(
      name: "MisakiSwift",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
      ],
      resources: [.copy("Resources")]
    ),
    .target(
      name: "KokoroSwift",
      dependencies: [
        "MisakiSwift",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXRandom", package: "mlx-swift"),
        .product(name: "MLXFFT", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
      ],
      resources: [.copy("Resources")]
    ),
  ]
)
