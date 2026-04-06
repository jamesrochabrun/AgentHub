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

  @Test("Failing a server leaves the failed state visible and clears external tracking")
  func failingServerLeavesFailedStateVisible() {
    let key = "test-\(UUID().uuidString)"
    DevServerManager.shared.connectToExistingServer(for: key, url: URL(string: "http://localhost:3000")!)

    DevServerManager.shared.failServer(for: key, error: "Connection refused")
    defer { DevServerManager.shared.stopServer(for: key) }

    guard case .failed(let error) = DevServerManager.shared.state(for: key) else {
      Issue.record("Expected failed server state")
      return
    }

    #expect(error == "Connection refused")
    #expect(DevServerManager.shared.isExternalServer(for: key) == false)
  }
}
