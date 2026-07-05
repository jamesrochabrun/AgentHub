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
      name: "AgentHubGitDiff",
      targets: ["AgentHubGitDiff"]
    ),
    .library(
      name: "AgentHubFileSearch",
      targets: ["AgentHubFileSearch"]
    ),
    .library(
      name: "AgentHubSessionGraph",
      targets: ["AgentHubSessionGraph"]
    ),
    .library(
      name: "AgentHubMCPUI",
      targets: ["AgentHubMCPUI"]
    ),
    .library(
      name: "AgentHubGlobalSessionPanel",
      targets: ["AgentHubGlobalSessionPanel"]
    ),
    .executable(
      name: "DiffBench",
      targets: ["DiffBench"]
    ),
  ],
  dependencies: [
    .package(path: "../AgentHubCLI"),
    .package(path: "../AgentHubGitHub"),
    .package(path: "../Storybook"),
    .package(path: "../SimulatorPreview"),
    .package(url: "https://github.com/jamesrochabrun/Canvas", exact: "1.2.2"),
    .package(url: "https://github.com/jamesrochabrun/PierreDiffsSwift", exact: "1.2.2"),
    .package(url: "https://github.com/jamesrochabrun/SwiftTerm", exact: "1.13.0-agenthub.8"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0"),
    .package(url: "https://github.com/appstefan/HighlightSwift", from: "1.1.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
    .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", from: "0.1.0"),
    .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor", exact: "0.15.2"),
    .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", exact: "0.1.20"),
  ],
  targets: [
    .systemLibrary(
      name: "CLibgit2",
      pkgConfig: "libgit2",
      providers: [
        .brew(["libgit2"])
      ]
    ),
    .target(
      name: "ClaudeCodeClient",
      path: "Sources/ClaudeCodeClient",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentHubGitDiff",
      dependencies: [
        "CLibgit2"
      ],
      path: "Sources/AgentHubGitDiff",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentHubFileSearch",
      path: "Sources/AgentHubFileSearch",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentHubSessionGraph",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Sources/AgentHubSessionGraph",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentHubMCPUI",
      path: "Sources/AgentHubMCPUI",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentHubGlobalSessionPanel",
      dependencies: [
        "AgentHubCore",
        .product(name: "AgentHubGitHub", package: "AgentHubGitHub"),
      ],
      path: "Sources/AgentHubGlobalSessionPanel",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    // Developer benchmark tool (not shipped in the app). Depends only on AgentHubGitDiff so it
    // builds without the heavy UI graph: `swift build --product DiffBench`. See CLAUDE.md.
    .executableTarget(
      name: "DiffBench",
      dependencies: ["AgentHubGitDiff"],
      path: "Sources/DiffBench",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
      name: "AgentHubCore",
      dependencies: [
        "ClaudeCodeClient",
        "AgentHubGitDiff",
        "AgentHubFileSearch",
        "AgentHubSessionGraph",
        "AgentHubMCPUI",
        .product(name: "AgentHubCLIKit", package: "AgentHubCLI"),
        .product(name: "AgentHubGitHub", package: "AgentHubGitHub"),
        .product(name: "Storybook", package: "Storybook"),
        .product(name: "SimulatorPreview", package: "SimulatorPreview"),
        .product(name: "Canvas", package: "Canvas"),
        .product(name: "PierreDiffsSwift", package: "PierreDiffsSwift"),
        .product(name: "SwiftTerm", package: "SwiftTerm"),
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
        .copy("Resources/AgentHubWorktreeSkill"),
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
      name: "AgentHubFileSearchTests",
      dependencies: ["AgentHubFileSearch"],
      path: "Tests/AgentHubFileSearchTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubSessionGraphTests",
      dependencies: ["AgentHubSessionGraph"],
      path: "Tests/AgentHubSessionGraphTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubMCPUITests",
      dependencies: ["AgentHubMCPUI"],
      path: "Tests/AgentHubMCPUITests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubGlobalSessionPanelTests",
      dependencies: [
        "AgentHubCore",
        "AgentHubGlobalSessionPanel",
        .product(name: "AgentHubGitHub", package: "AgentHubGitHub"),
      ],
      path: "Tests/AgentHubGlobalSessionPanelTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubTests",
      dependencies: [
        "AgentHubCore",
        .product(name: "AgentHubCLIKit", package: "AgentHubCLI"),
        "AgentHubGitDiff",
        "AgentHubFileSearch",
        "ClaudeCodeClient",
      ],
      path: "Tests/AgentHubTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
