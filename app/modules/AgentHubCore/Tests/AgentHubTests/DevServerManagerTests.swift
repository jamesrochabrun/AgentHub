import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("DevServerManager")
struct DevServerManagerTests {

  @Test("Vite readiness patterns avoid matching the echoed framework command")
  func viteReadinessPatternsAvoidCommandEcho() throws {
    let projectURL = try makeProjectFixture(
      packageJSON: """
      {
        "name": "vite-fixture",
        "scripts": {
          "dev": "vite"
        },
        "devDependencies": {
          "vite": "^5.0.0"
        }
      }
      """
    )
    defer { try? FileManager.default.removeItem(at: projectURL) }

    let detected = DevServerManager.detectProject(at: projectURL.path)

    #expect(detected.framework == .vite)
    #expect(detected.readinessPatterns.contains(where: { $0.lowercased() == "vite" }) == false)
    #expect(detected.readinessPatterns.contains("ready in"))
    #expect(detected.readinessPatterns.contains("localhost:"))
  }

  @Test("Astro readiness patterns avoid matching the echoed framework command")
  func astroReadinessPatternsAvoidCommandEcho() throws {
    let projectURL = try makeProjectFixture(
      packageJSON: """
      {
        "name": "astro-fixture",
        "scripts": {
          "dev": "astro dev"
        },
        "dependencies": {
          "astro": "^5.0.0"
        }
      }
      """
    )
    defer { try? FileManager.default.removeItem(at: projectURL) }

    let detected = DevServerManager.detectProject(at: projectURL.path)

    #expect(detected.framework == .astro)
    #expect(detected.readinessPatterns.contains(where: { $0.lowercased() == "astro" }) == false)
    #expect(detected.readinessPatterns.contains("ready in"))
    #expect(detected.readinessPatterns.contains("localhost:"))
  }

  @Test("Sanitizes malformed agent localhost URL before connecting")
  func sanitizesMalformedAgentLocalhostURLBeforeConnecting() {
    let key = "test-\(UUID().uuidString)"
    let malformedURL = URL(string: "http://localhost:3000/**.")!

    DevServerManager.shared.connectToExistingServer(for: key, url: malformedURL)
    defer { DevServerManager.shared.stopServer(for: key) }

    let state: DevServerState = DevServerManager.shared.state(for: key)
    guard case .ready(let url) = state else {
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

    let state: DevServerState = DevServerManager.shared.state(for: key)
    guard case .failed(let error) = state else {
      Issue.record("Expected failed server state")
      return
    }

    #expect(error == "Connection refused")
    #expect(DevServerManager.shared.isExternalServer(for: key) == false)
  }

  @Test("Storybook server uses compound key with :storybook suffix")
  func storybookServerUsesCompoundKey() {
    let sessionId = "test-\(UUID().uuidString)"
    let storybookKey = "\(sessionId):storybook"

    let initialStorybookState: DevServerState = DevServerManager.shared.state(for: storybookKey)
    #expect(initialStorybookState == .idle)

    let url = URL(string: "http://localhost:6006")!
    DevServerManager.shared.connectToExistingServer(for: storybookKey, url: url)
    defer { DevServerManager.shared.stopServer(for: storybookKey) }

    guard case .ready(let readyURL) = DevServerManager.shared.storybookState(for: sessionId) else {
      Issue.record("Expected ready storybook server state")
      return
    }
    #expect(readyURL.absoluteString == "http://localhost:6006")

    let appState: DevServerState = DevServerManager.shared.state(for: sessionId)
    #expect(appState == .idle)
  }

  private func makeProjectFixture(packageJSON: String) throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("DevServerManagerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try packageJSON.write(
      to: rootURL.appendingPathComponent("package.json"),
      atomically: true,
      encoding: .utf8
    )
    return rootURL
  }
}
