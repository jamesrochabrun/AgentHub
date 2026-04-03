import Foundation
import Testing
@testable import SwiftUIPreviewKit

@Suite("PreviewHostGenerator")
struct PreviewHostGeneratorTests {

  private func samplePreview(
    name: String? = "Test",
    filePath: String = "/Users/dev/MyApp/ContentView.swift",
    lineNumber: Int = 10,
    bodyExpression: String = "Text(\"Hello\")",
    moduleName: String? = "MyApp"
  ) -> PreviewDeclaration {
    PreviewDeclaration(
      name: name,
      filePath: filePath,
      lineNumber: lineNumber,
      bodyExpression: bodyExpression,
      moduleName: moduleName
    )
  }

  // MARK: - generateAppSwift

  @Test func generatedSwiftImportsModule() {
    let preview = samplePreview(moduleName: "FeatureKit")
    let swift = PreviewHostGenerator.generateAppSwift(for: preview, scheme: "FeatureKit")
    #expect(swift.contains("import FeatureKit"))
    #expect(swift.contains("import SwiftUI"))
  }

  @Test func generatedSwiftContainsBodyExpression() {
    let preview = samplePreview(bodyExpression: "VStack { Text(\"Preview\") }")
    let swift = PreviewHostGenerator.generateAppSwift(for: preview, scheme: "MyApp")
    #expect(swift.contains("VStack { Text(\"Preview\") }"))
  }

  @Test func generatedSwiftUsesSchemeWhenModuleNameIsNil() {
    let preview = samplePreview(moduleName: nil)
    let swift = PreviewHostGenerator.generateAppSwift(for: preview, scheme: "FallbackScheme")
    #expect(swift.contains("import FallbackScheme"))
  }

  @Test func generatedSwiftIsMainApp() {
    let preview = samplePreview()
    let swift = PreviewHostGenerator.generateAppSwift(for: preview, scheme: "MyApp")
    #expect(swift.contains("@main"))
    #expect(swift.contains("struct PreviewHostApp: App"))
    #expect(swift.contains("WindowGroup"))
  }

  // MARK: - generatePbxproj

  @Test func pbxprojContainsFrameworkSearchPaths() {
    let pbxproj = PreviewHostGenerator.generatePbxproj(
      bundleIdentifier: "com.test",
      userDerivedDataPath: "/tmp/DD",
      scheme: "MyApp"
    )
    #expect(pbxproj.contains("/tmp/DD/Build/Products/Debug-iphonesimulator"))
  }

  @Test func pbxprojContainsSwiftIncludePaths() {
    let pbxproj = PreviewHostGenerator.generatePbxproj(
      bundleIdentifier: "com.test",
      userDerivedDataPath: "/tmp/DD",
      scheme: "MyApp"
    )
    #expect(pbxproj.contains("SWIFT_INCLUDE_PATHS"))
    #expect(pbxproj.contains("/tmp/DD/Build/Products/Debug-iphonesimulator"))
  }

  @Test func pbxprojContainsBundleIdentifier() {
    let pbxproj = PreviewHostGenerator.generatePbxproj(
      bundleIdentifier: "com.agenthub.previewhost.abc123",
      userDerivedDataPath: "/tmp/DD",
      scheme: "MyApp"
    )
    #expect(pbxproj.contains("com.agenthub.previewhost.abc123"))
  }

  @Test func pbxprojTargetsIOSSimulator() {
    let pbxproj = PreviewHostGenerator.generatePbxproj(
      bundleIdentifier: "com.test",
      userDerivedDataPath: "/tmp/DD",
      scheme: "MyApp"
    )
    #expect(pbxproj.contains("SDKROOT = iphoneos"))
    #expect(pbxproj.contains("TARGETED_DEVICE_FAMILY = \"1,2\""))
  }

  // MARK: - bundleIdentifier

  @Test func bundleIdentifierIsDeterministic() {
    let preview = samplePreview()
    let id1 = PreviewHostGenerator.bundleIdentifier(for: preview, scheme: "MyApp")
    let id2 = PreviewHostGenerator.bundleIdentifier(for: preview, scheme: "MyApp")
    #expect(id1 == id2)
  }

  @Test func bundleIdentifierDiffersForDifferentPreviews() {
    let preview1 = samplePreview(lineNumber: 10)
    let preview2 = samplePreview(lineNumber: 20)
    let id1 = PreviewHostGenerator.bundleIdentifier(for: preview1, scheme: "MyApp")
    let id2 = PreviewHostGenerator.bundleIdentifier(for: preview2, scheme: "MyApp")
    #expect(id1 != id2)
  }

  @Test func bundleIdentifierHasCorrectPrefix() {
    let preview = samplePreview()
    let id = PreviewHostGenerator.bundleIdentifier(for: preview, scheme: "MyApp")
    #expect(id.hasPrefix("com.agenthub.previewhost."))
  }
}
