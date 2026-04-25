import Foundation
import Testing

@testable import AgentHubCore

@Suite("WebPreviewMode")
struct WebPreviewModeTests {

  // MARK: - serverKey

  @Test("App mode uses the plain session ID")
  func appModeUsesPlainSessionId() {
    #expect(WebPreviewMode.app.serverKey(for: "abc-123") == "abc-123")
  }

  @Test("Storybook mode uses the compound :storybook key")
  func storybookModeUsesCompoundKey() {
    #expect(WebPreviewMode.storybook.serverKey(for: "abc-123") == "abc-123:storybook")
  }

  @Test("App and Storybook keys never collide for the same session")
  func keysNeverCollide() {
    let sessionId = "session-\(UUID().uuidString)"
    let appKey = WebPreviewMode.app.serverKey(for: sessionId)
    let storybookKey = WebPreviewMode.storybook.serverKey(for: sessionId)
    #expect(appKey != storybookKey)
  }

  // MARK: - End-to-end mode → DevServerManager routing

  @MainActor
  @Test("Storybook mode reads from the same key DevServerManager.startStorybookServer writes to")
  func storybookModeReadsFromCorrectKey() {
    let sessionId = "routing-\(UUID().uuidString)"
    let url = URL(string: "http://localhost:6006")!

    // Simulate Storybook starting under the compound key (as startStorybookServer does)
    DevServerManager.shared.connectToExistingServer(
      for: WebPreviewMode.storybook.serverKey(for: sessionId),
      url: url
    )
    defer {
      DevServerManager.shared.stopServer(for: WebPreviewMode.storybook.serverKey(for: sessionId))
    }

    // The Storybook-mode key resolves to the running storybook server,
    // and the App-mode key for the same session stays idle.
    guard case .ready(let storybookURL) = DevServerManager.shared.state(
      for: WebPreviewMode.storybook.serverKey(for: sessionId)
    ) else {
      Issue.record("Expected storybook key to be .ready")
      return
    }
    #expect(storybookURL.absoluteString == "http://localhost:6006")
    #expect(DevServerManager.shared.state(for: WebPreviewMode.app.serverKey(for: sessionId)) == .idle)
  }
}
