// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AgentHubCore",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "AgentHubCore",
      targets: ["AgentHubCore"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/jamesrochabrun/ClaudeCodeSDK", exact: "1.2.4"),
    .package(url: "https://github.com/jamesrochabrun/PierreDiffsSwift", exact: "1.1.4"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0"),
    .package(url: "https://github.com/appstefan/HighlightSwift", from: "1.1.0"),
  ],
  targets: [
    .target(
      name: "AgentHubCore",
      dependencies: [
        .product(name: "ClaudeCodeSDK", package: "ClaudeCodeSDK"),
        .product(name: "PierreDiffsSwift", package: "PierreDiffsSwift"),
        .product(name: "SwiftTerm", package: "SwiftTerm"),
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "HighlightSwift", package: "HighlightSwift"),
      ],
      path: "Sources/AgentHub",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubTests",
      dependencies: ["AgentHubCore"],
      path: "Tests/AgentHubTests"
    ),
  ]
)
