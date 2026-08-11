// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AgentHubVoice",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "AgentHubVoice",
      targets: ["AgentHubVoice"]
    ),
    .library(
      name: "AgentHubVoicePanel",
      targets: ["AgentHubVoicePanel"]
    ),
  ],
  dependencies: [
    // Pinned to the fork revision with the realtime audio-graph fixes.
    // For local SwiftOpenAI iteration, temporarily swap in:
    //   .package(path: "../../../../SwiftOpenAI")
    .package(
      url: "https://github.com/jamesrochabrun/SwiftOpenAI.git",
      revision: "9bac840febf58a294afd2761d012e793c3490c75"
    )
  ],
  targets: [
    .target(
      name: "AgentHubVoice",
      dependencies: [
        .product(name: "SwiftOpenAI", package: "SwiftOpenAI")
      ],
      path: "Sources/AgentHubVoice",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentHubVoicePanel",
      dependencies: ["AgentHubVoice"],
      path: "Sources/AgentHubVoicePanel",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubVoiceTests",
      dependencies: ["AgentHubVoice"],
      path: "Tests/AgentHubVoiceTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubVoicePanelTests",
      dependencies: ["AgentHubVoicePanel"],
      path: "Tests/AgentHubVoicePanelTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    )
  ]
)
