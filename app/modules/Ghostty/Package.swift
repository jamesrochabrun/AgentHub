// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Ghostty",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "Ghostty",
      targets: ["Ghostty"]
    ),
  ],
  dependencies: [
    .package(path: "../AgentHubCore"),
    .package(url: "https://github.com/jamesrochabrun/GhosttySwift", exact: "1.0.3"),
  ],
  targets: [
    .target(
      name: "Ghostty",
      dependencies: [
        .product(name: "AgentHubCore", package: "AgentHubCore"),
        .product(name: "GhosttySwift", package: "GhosttySwift"),
      ],
      path: "Sources/Ghostty",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "GhosttyTests",
      dependencies: ["Ghostty"],
      path: "Tests/GhosttyTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
