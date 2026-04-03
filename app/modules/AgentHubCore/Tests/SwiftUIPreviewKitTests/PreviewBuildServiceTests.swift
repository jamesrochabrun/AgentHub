import Foundation
import Testing
@testable import SwiftUIPreviewKit

// MARK: - Mocks

final class MockPreviewScanner: PreviewScannerProtocol {
  var stubbedPreviews: [PreviewDeclaration] = []

  func scanForPreviews(in projectPath: String, moduleName: String?) async -> [PreviewDeclaration] {
    stubbedPreviews
  }

  func scanFile(at filePath: String, moduleName: String?) -> [PreviewDeclaration] {
    stubbedPreviews.filter { $0.filePath == filePath }
  }
}

final class MockPreviewHostGenerator: PreviewHostGeneratorProtocol {
  var stubbedHost: GeneratedPreviewHost?
  var generateError: Error?

  func generateHostProject(
    for preview: PreviewDeclaration,
    userDerivedDataPath: String,
    scheme: String
  ) async throws -> GeneratedPreviewHost {
    if let error = generateError { throw error }
    return stubbedHost ?? GeneratedPreviewHost(
      projectPath: "/tmp/PreviewHost.xcodeproj",
      scheme: "PreviewHost",
      bundleIdentifier: "com.agenthub.previewhost.test",
      derivedDataPath: "/tmp/DerivedData"
    )
  }
}

final class MockSimulatorScreenshotService: SimulatorScreenshotServiceProtocol {
  var capturedUDIDs: [String] = []
  var captureError: Error?

  func captureScreenshot(udid: String, outputPath: String) async throws {
    if let error = captureError { throw error }
    capturedUDIDs.append(udid)
    // Create a dummy file so the service can find it
    FileManager.default.createFile(atPath: outputPath, contents: Data([0x89, 0x50, 0x4E, 0x47]))
  }

  func startPolling(
    udid: String,
    interval: TimeInterval,
    onChange: @escaping @Sendable (String) -> Void
  ) async -> UUID {
    UUID()
  }

  func stopPolling(id: UUID) async {}
}

// MARK: - PreviewBuildState Tests

@Suite("PreviewBuildState")
struct PreviewBuildStateTests {

  @Test func idleIsNotBuilding() {
    #expect(!PreviewBuildState.idle.isBuilding)
  }

  @Test func buildingStatesAreBuilding() {
    #expect(PreviewBuildState.buildingUserProject.isBuilding)
    #expect(PreviewBuildState.generatingHost.isBuilding)
    #expect(PreviewBuildState.buildingHost.isBuilding)
    #expect(PreviewBuildState.installing.isBuilding)
    #expect(PreviewBuildState.capturing.isBuilding)
  }

  @Test func readyIsNotBuilding() {
    #expect(!PreviewBuildState.ready(imagePath: "/tmp/img.png").isBuilding)
  }

  @Test func failedIsNotBuilding() {
    #expect(!PreviewBuildState.failed(error: "oops").isBuilding)
  }

  @Test func phaseLabelsExistForBuildStates() {
    #expect(PreviewBuildState.scanningPreviews.phaseLabel != nil)
    #expect(PreviewBuildState.buildingUserProject.phaseLabel != nil)
    #expect(PreviewBuildState.generatingHost.phaseLabel != nil)
    #expect(PreviewBuildState.buildingHost.phaseLabel != nil)
    #expect(PreviewBuildState.installing.phaseLabel != nil)
    #expect(PreviewBuildState.capturing.phaseLabel != nil)
  }

  @Test func phaseLabelIsNilForIdle() {
    #expect(PreviewBuildState.idle.phaseLabel == nil)
  }

  @Test func phaseLabelIsNilForReady() {
    #expect(PreviewBuildState.ready(imagePath: "/tmp/img.png").phaseLabel == nil)
  }

  @Test func phaseLabelIsNilForFailed() {
    #expect(PreviewBuildState.failed(error: "oops").phaseLabel == nil)
  }
}

// MARK: - PreviewBuildService Tests

@Suite("PreviewBuildService")
struct PreviewBuildServiceTests {

  private func makeSamplePreview() -> PreviewDeclaration {
    PreviewDeclaration(
      name: "Test",
      filePath: "/tmp/TestView.swift",
      lineNumber: 5,
      bodyExpression: "Text(\"Hello\")",
      moduleName: "TestApp"
    )
  }

  @MainActor
  @Test func scanPreviewsPopulatesResults() async {
    let scanner = MockPreviewScanner()
    let preview = makeSamplePreview()
    scanner.stubbedPreviews = [preview]

    let service = PreviewBuildService(
      scanner: scanner,
      hostGenerator: MockPreviewHostGenerator(),
      screenshotService: MockSimulatorScreenshotService()
    )

    await service.scanPreviews(projectPath: "/tmp/project", moduleName: nil)
    #expect(service.previews.count == 1)
    #expect(service.previews[0].name == "Test")
    #expect(service.buildState == .idle)
  }

  @MainActor
  @Test func scanPreviewsEmptyResult() async {
    let scanner = MockPreviewScanner()
    scanner.stubbedPreviews = []

    let service = PreviewBuildService(
      scanner: scanner,
      hostGenerator: MockPreviewHostGenerator(),
      screenshotService: MockSimulatorScreenshotService()
    )

    await service.scanPreviews(projectPath: "/tmp/project", moduleName: nil)
    #expect(service.previews.isEmpty)
    #expect(service.buildState == .idle)
  }

  @MainActor
  @Test func cancelBuildResetsState() async {
    let service = PreviewBuildService(
      scanner: MockPreviewScanner(),
      hostGenerator: MockPreviewHostGenerator(),
      screenshotService: MockSimulatorScreenshotService()
    )

    service.cancelBuild()
    #expect(service.buildState == .idle)
    #expect(service.capturedImagePath == nil)
  }

  @MainActor
  @Test func buildPreviewFailsWithoutCallback() async {
    let service = PreviewBuildService(
      scanner: MockPreviewScanner(),
      hostGenerator: MockPreviewHostGenerator(),
      screenshotService: MockSimulatorScreenshotService()
    )
    // Don't set onBuildUserProject

    let preview = makeSamplePreview()
    await service.buildPreview(preview, udid: "test-udid", projectPath: "/tmp/project")

    // Give the task a moment to complete
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(service.selectedPreview == preview)
    if case .failed(let error) = service.buildState {
      #expect(error.contains("callback"))
    } else {
      #expect(Bool(false), "Expected failed state")
    }
  }

  // MARK: - extractBuildErrors

  @Test func extractBuildErrorsFindsErrorLines() {
    let output = """
    CompileSwift normal arm64 /tmp/Test.swift
    /tmp/Test.swift:5:10: error: cannot find 'MyView' in scope
    /tmp/Test.swift:8:3: error: missing return
    ** BUILD FAILED **
    """
    let errors = PreviewBuildService.extractBuildErrors(from: output)
    #expect(errors.contains("cannot find 'MyView' in scope"))
    #expect(errors.contains("missing return"))
  }

  @Test func extractBuildErrorsFallsBackToTail() {
    let output = "Some generic build output\nwithout error markers"
    let errors = PreviewBuildService.extractBuildErrors(from: output)
    #expect(errors.contains("Some generic build output"))
  }
}
