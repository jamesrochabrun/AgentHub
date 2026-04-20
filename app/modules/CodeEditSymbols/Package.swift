// swift-tools-version: 5.5

import PackageDescription

let package = Package(
  name: "CodeEditSymbols",
  platforms: [
    .macOS(.v12),
  ],
  products: [
    .library(
      name: "CodeEditSymbols",
      targets: ["CodeEditSymbols"]
    ),
  ],
  targets: [
    .target(
      name: "CodeEditSymbols",
      resources: [
        .process("Symbols.xcassets"),
      ]
    ),
  ]
)
