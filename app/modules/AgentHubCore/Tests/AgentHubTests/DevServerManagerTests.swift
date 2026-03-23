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
}
