// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "AgentHub",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "AgentHub",
      targets: ["AgentHub"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/jamesrochabrun/ClaudeCodeSDK", exact: "1.2.4"),
  ],
  targets: [
    .target(
      name: "AgentHub",
      dependencies: [
        .product(name: "ClaudeCodeSDK", package: "ClaudeCodeSDK"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubTests",
      dependencies: ["AgentHub"]
    ),
  ]
)
