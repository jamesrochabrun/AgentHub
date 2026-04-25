// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Storybook",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "Storybook",
      targets: ["Storybook"]
    ),
  ],
  targets: [
    .target(
      name: "Storybook",
      path: "Sources/Storybook",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "StorybookTests",
      dependencies: ["Storybook"],
      path: "Tests/StorybookTests",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
