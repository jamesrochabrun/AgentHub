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
    .package(url: "https://github.com/jamesrochabrun/PierreDiffsSwift", exact: "1.1.4"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
  ],
  targets: [
    .target(
      name: "AgentHub",
      dependencies: [
        .product(name: "ClaudeCodeSDK", package: "ClaudeCodeSDK"),
        .product(name: "PierreDiffsSwift", package: "PierreDiffsSwift"),
        .product(name: "SwiftTerm", package: "SwiftTerm"),
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
