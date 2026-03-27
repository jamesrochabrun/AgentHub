import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("DevServerManager")
struct DevServerManagerTests {

  @Test("Sanitizes malformed agent localhost URL before connecting")
  func sanitizesMalformedAgentLocalhostURLBeforeConnecting() {
    let key = "test-\(UUID().uuidString)"
    let malformedURL = URL(string: "http://localhost:3000/**.")!

    DevServerManager.shared.connectToExistingServer(for: key, url: malformedURL)
    defer { DevServerManager.shared.stopServer(for: key) }

    guard case .ready(let url) = DevServerManager.shared.state(for: key) else {
      Issue.record("Expected ready server state")
      return
    }

    #expect(url.absoluteString == "http://localhost:3000")
  }

  @Test("Storybook server uses compound key with :storybook suffix")
  func storybookServerUsesCompoundKey() {
    let sessionId = "test-\(UUID().uuidString)"
    let storybookKey = "\(sessionId):storybook"

    // Initially idle
    #expect(DevServerManager.shared.storybookState(for: sessionId) == .idle)
    #expect(DevServerManager.shared.state(for: storybookKey) == .idle)

    // Connect an external storybook server to verify the compound key
    let url = URL(string: "http://localhost:6006")!
    DevServerManager.shared.connectToExistingServer(for: storybookKey, url: url)
    defer { DevServerManager.shared.stopServer(for: storybookKey) }

    // Should be ready under the compound key
    guard case .ready(let readyURL) = DevServerManager.shared.storybookState(for: sessionId) else {
      Issue.record("Expected ready storybook server state")
      return
    }
    #expect(readyURL.absoluteString == "http://localhost:6006")

    // The primary session key should still be idle
    #expect(DevServerManager.shared.state(for: sessionId) == .idle)
  }
}
