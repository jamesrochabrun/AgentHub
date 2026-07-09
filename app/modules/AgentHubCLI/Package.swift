// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AgentHubCLI",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "AgentHubCLIKit",
      targets: ["AgentHubCLIKit"]
    ),
    .executable(
      name: "agenthub",
      targets: ["AgentHubCLI"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(path: "../SimulatorPreview"),
  ],
  targets: [
    .target(
      name: "AgentHubCLIKit",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .executableTarget(
      name: "AgentHubCLI",
      dependencies: [
        "AgentHubCLIKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        // Reuses the AX-inspection bridge for agenthub_simulator_describe_ui.
        .product(name: "SimulatorPreview", package: "SimulatorPreview"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentHubCLIKitTests",
      dependencies: ["AgentHubCLIKit"],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
