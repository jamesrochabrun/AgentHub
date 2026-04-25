import Foundation
import Testing
import Storybook

@testable import AgentHubCore

@Suite("Storybook Integration")
struct StorybookIntegrationTests {

  // MARK: - ProjectFramework delegates to StorybookDetector

  @Test("ProjectFramework.hasStorybook delegates to StorybookDetector")
  func delegatesToStorybookDetector() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("storybook-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    #expect(!ProjectFramework.hasStorybook(at: tmpDir.path))
    #expect(!StorybookDetector.hasStorybook(at: tmpDir.path))

    try FileManager.default.createDirectory(
      at: tmpDir.appendingPathComponent(".storybook"),
      withIntermediateDirectories: true
    )

    #expect(ProjectFramework.hasStorybook(at: tmpDir.path))
    #expect(StorybookDetector.hasStorybook(at: tmpDir.path))
  }

  @Test("Storybook framework requires dev server")
  func storybookRequiresDevServer() {
    #expect(ProjectFramework.storybook.requiresDevServer)
  }

  // MARK: - DevServerManager conforms to StorybookService

  @MainActor
  @Test("DevServerManager conforms to StorybookService protocol")
  func devServerManagerConformsToStorybookService() {
    let service: any StorybookService = DevServerManager.shared
    let sessionId = "conformance-test-\(UUID().uuidString)"

    #expect(service.state(for: sessionId) == .idle)
  }

  @MainActor
  @Test("StorybookService state maps DevServerState correctly")
  func storybookServiceStateMapsCorrectly() {
    let sessionId = "state-test-\(UUID().uuidString)"
    let storybookKey = "\(sessionId):storybook"

    let url = URL(string: "http://localhost:6006")!
    DevServerManager.shared.connectToExistingServer(for: storybookKey, url: url)
    defer { DevServerManager.shared.stopServer(for: storybookKey) }

    let service: any StorybookService = DevServerManager.shared
    guard case .ready(let readyURL) = service.state(for: sessionId) else {
      Issue.record("Expected .ready state from StorybookService")
      return
    }
    #expect(readyURL.absoluteString == "http://localhost:6006")
  }
}
