// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SimulatorPreview",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "SimulatorPreview",
      targets: ["SimulatorPreview"]
    ),
    .executable(
      name: "SimulatorPreviewProbe",
      targets: ["SimulatorPreviewProbe"]
    ),
    .executable(
      name: "SimulatorAXProbe",
      targets: ["SimulatorAXProbe"]
    ),
  ],
  targets: [
    .target(
      name: "SimulatorPreview",
      path: "Sources/SimulatorPreview",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    // Local verification harness — never shipped in the app.
    .executableTarget(
      name: "SimulatorPreviewProbe",
      dependencies: ["SimulatorPreview"],
      path: "Sources/SimulatorPreviewProbe",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    // Local verification harness for the accessibility-tree path — never shipped.
    .executableTarget(
      name: "SimulatorAXProbe",
      dependencies: ["SimulatorPreview"],
      path: "Sources/SimulatorAXProbe",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "SimulatorPreviewTests",
      dependencies: ["SimulatorPreview"],
      path: "Tests/SimulatorPreviewTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
