// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "CodeEditSourceEditor",
  platforms: [.macOS(.v13)],
  products: [
    .library(
      name: "CodeEditSourceEditor",
      targets: ["CodeEditSourceEditor"]
    )
  ],
  dependencies: [
    .package(
      url: "https://github.com/CodeEditApp/CodeEditTextView.git",
      from: "0.12.1"
    ),
    .package(
      url: "https://github.com/CodeEditApp/CodeEditLanguages.git",
      exact: "0.1.20"
    ),
    .package(path: "../CodeEditSymbols"),
    .package(
      url: "https://github.com/ChimeHQ/TextFormation",
      from: "0.8.2"
    )
  ],
  targets: [
    .target(
      name: "CodeEditSourceEditor",
      dependencies: [
        "CodeEditTextView",
        "CodeEditLanguages",
        "TextFormation",
        "CodeEditSymbols"
      ]
    )
  ]
)
