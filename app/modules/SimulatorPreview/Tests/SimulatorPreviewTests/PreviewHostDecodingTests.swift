import Foundation
import Testing

@testable import SimulatorPreview

@Suite("PreviewHostDecoding")
struct PreviewHostDecodingTests {

  @Test("manifest decodes types, names, and preview counts")
  func manifest() throws {
    let json = """
    [
      {"typeName": "MyApp.HomeView_Previews", "numPreviews": 2,
       "devices": ["", ""], "orientations": ["portrait", "portrait"]},
      {"typeName": "$s5MyApp17HomePreviews33_fMf", "numPreviews": 1,
       "displayName": "MyApp/HomeView.swift:Dark Mode"},
      {"noTypeName": true}
    ]
    """
    let types = try PreviewHostDecoding.decodeManifest(Data(json.utf8))

    #expect(types.count == 2)
    #expect(types[0].typeName == "MyApp.HomeView_Previews")
    #expect(types[0].numPreviews == 2)
    #expect(types[0].previewIds == ["0", "1"])
    #expect(types[1].displayName == "MyApp/HomeView.swift:Dark Mode")
    #expect(types[1].previewIds == ["0"])
  }

  @Test("card title prefers the #Preview display name, then the file name")
  func cardTitles() {
    let named = PreviewHostPreviewType(
      typeName: "$sX", displayName: "MyApp/HomeView.swift:Dark Mode", numPreviews: 1)
    #expect(named.cardTitle == "Dark Mode")
    #expect(named.moduleName == "MyApp")

    let unnamed = PreviewHostPreviewType(
      typeName: "$sY", displayName: "MyApp/HomeView.swift", numPreviews: 1)
    #expect(unnamed.cardTitle == "HomeView")

    let provider = PreviewHostPreviewType(
      typeName: "MyApp.HomeView_Previews", displayName: nil, numPreviews: 1)
    #expect(provider.cardTitle == "MyApp.HomeView_Previews")
    #expect(provider.moduleName == nil)
  }

  @Test("render response loads image bytes from the shared filesystem")
  func renderSuccess() throws {
    let json = """
    {"displayName": "Dark Mode", "imagePath": "/sim/Documents/EMGSnapshots/T-0.png", "scale": 3}
    """
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let result = try PreviewHostDecoding.decodeRender(Data(json.utf8)) { path in
      path == "/sim/Documents/EMGSnapshots/T-0.png" ? png : nil
    }
    #expect(result.displayName == "Dark Mode")
    #expect(result.imageData == png)
    #expect(result.scale == 3)
    #expect(result.errorMessage == nil)
  }

  @Test("changed-file matching: registries by fileID, providers by convention")
  func sourceMatching() {
    let registry = PreviewHostPreviewType(
      typeName: "MathGame.$s8MathGameLl7PreviewfMf_15PreviewRegistryfMu_",
      displayName: "MathGame/GradientButton.swift:Interactive",
      numPreviews: 1)
    #expect(registry.sourceFileName == "GradientButton.swift")
    #expect(registry.matchesSource(fileNames: ["GradientButton.swift"]))
    #expect(!registry.matchesSource(fileNames: ["OtherView.swift"]))

    let provider = PreviewHostPreviewType(
      typeName: "MathGame.HomeView_Previews", displayName: nil, numPreviews: 1)
    #expect(provider.sourceFileName == nil)
    #expect(provider.matchesSource(fileNames: ["HomeView.swift"]))
    #expect(!provider.matchesSource(fileNames: ["HomeViewModel.swift"]))

    let unconventional = PreviewHostPreviewType(
      typeName: "MathGame.SomeRandomType", displayName: nil, numPreviews: 1)
    #expect(!unconventional.matchesSource(fileNames: ["SomeRandomType.swift"]))
  }

  @Test("render error passes the message through")
  func renderError() throws {
    let json = """
    {"error": "Error converting image to png"}
    """
    let result = try PreviewHostDecoding.decodeRender(Data(json.utf8)) { _ in nil }
    #expect(result.imageData == nil)
    #expect(result.errorMessage == "Error converting image to png")
  }

  @Test("malformed payloads throw")
  func malformed() {
    #expect(throws: PreviewHostClientError.self) {
      try PreviewHostDecoding.decodeManifest(Data("{}".utf8))
    }
    #expect(throws: PreviewHostClientError.self) {
      try PreviewHostDecoding.decodeRender(Data("[]".utf8)) { _ in nil }
    }
  }
}
