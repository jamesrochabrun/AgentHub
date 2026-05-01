// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AgentHubCore",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "ClaudeCodeClient",
      targets: ["ClaudeCodeClient"]
    ),
    .library(
      name: "AgentHubCore",
      targets: ["AgentHubCore"]
    ),
    .library(
      name: "AgentHubTerminalUI",
      targets: ["AgentHubTerminalUI"]
    ),
  ],
  dependencies: [
    .package(path: "../AgentHubGitHub"),
    .package(path: "../Storybook"),
    .package(url: "https://github.com/jamesrochabrun/Canvas", from: "1.2.0"),
    .package(url: "https://github.com/jamesrochabrun/PierreDiffsSwift", exact: "1.1.7"),
    .package(url: "https://github.com/jamesrochabrun/SwiftTerm", exact: "1.13.0-agenthub.1"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0"),
    .package(url: "https://github.com/appstefan/HighlightSwift", from: "1.1.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
    .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", from: "0.1.0"),
    .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor", exact: "0.15.2"),
    .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", exact: "0.1.20"),
  ],
  targets: [
    .target(
      name: "ClaudeCodeClient",
      path: "Sources/ClaudeCodeClient",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentHubTerminalUI",
      dependencies: [
        .product(name: "SwiftTerm", package: "SwiftTerm"),
      ],
      path: "Sources/AgentHubTerminalUI",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentHubCore",
      dependencies: [
        "ClaudeCodeClient",
        "AgentHubTerminalUI",
        .product(name: "AgentHubGitHub", package: "AgentHubGitHub"),
        .product(name: "Storybook", package: "Storybook"),
        .product(name: "Canvas", package: "Canvas"),
        .product(name: "PierreDiffsSwift", package: "PierreDiffsSwift"),
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "HighlightSwift", package: "HighlightSwift"),
        .product(name: "Yams", package: "Yams"),
        .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
        .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
        .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
      ],
      path: "Sources/AgentHub",
      resources: [
        .copy("Design/Theme/BundledThemes"),
        .copy("Resources/ClaudeHook"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "ClaudeCodeClientTests",
      dependencies: ["ClaudeCodeClient"],
      path: "Tests/ClaudeCodeClientTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubTests",
      dependencies: [
        "AgentHubCore",
        "AgentHubTerminalUI",
        "ClaudeCodeClient",
      ],
      path: "Tests/AgentHubTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
