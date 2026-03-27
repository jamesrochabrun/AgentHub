// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Canvas",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "Canvas",
      targets: ["Canvas"]
    ),
  ],
  targets: [
    .target(
      name: "Canvas",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "CanvasTests",
      dependencies: ["Canvas"],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
