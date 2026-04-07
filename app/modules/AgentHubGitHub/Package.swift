// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AgentHubGitHub",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "AgentHubGitHub",
      targets: ["AgentHubGitHub"]
    ),
  ],
  targets: [
    .target(
      name: "AgentHubGitHub",
      path: "Sources/AgentHubGitHub",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubGitHubTests",
      dependencies: ["AgentHubGitHub"],
      path: "Tests/AgentHubGitHubTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
