import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("SimulatorSessionContextStore")
struct SimulatorSessionContextStoreTests {
  @Test("Write and resolve preserve the active panel context")
  func writeAndResolveContext() throws {
    let directory = try temporarySimulatorContextDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = SimulatorSessionContextStore(directoryURL: directory)
    let context = SimulatorSessionContext(
      provider: .codex,
      sessionId: "session-1",
      projectPath: "/tmp/App",
      udid: "UDID-1",
      deviceName: "iPhone 17 Pro",
      runtimeName: "iOS 26.0",
      isBooted: true,
      displayMode: "live",
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    try store.write(context)

    #expect(try store.context(provider: .codex, sessionId: "session-1", projectPath: "/tmp/App") == context)
    #expect(try store.resolveContext(provider: .codex, sessionId: "session-1", projectPath: "/tmp/App") == context)
  }

  @Test("Resolve falls back to the newest visible context for the project")
  func resolveProjectFallbackUsesNewestVisibleContext() throws {
    let directory = try temporarySimulatorContextDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = SimulatorSessionContextStore(directoryURL: directory)
    let older = SimulatorSessionContext(
      provider: .claude,
      sessionId: "older",
      projectPath: "/tmp/App/",
      udid: "OLD",
      deviceName: nil,
      runtimeName: nil,
      isBooted: false,
      displayMode: "live",
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    let newer = SimulatorSessionContext(
      provider: .codex,
      sessionId: "newer",
      projectPath: "/tmp/App",
      udid: "NEW",
      deviceName: nil,
      runtimeName: nil,
      isBooted: true,
      displayMode: "previews",
      updatedAt: Date(timeIntervalSince1970: 2_000)
    )

    try store.write(older)
    try store.write(newer)

    #expect(try store.resolveContext(provider: nil, sessionId: nil, projectPath: "/tmp/App") == newer)
  }

  @Test("Remove deletes a stale panel context")
  func removeDeletesContext() throws {
    let directory = try temporarySimulatorContextDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = SimulatorSessionContextStore(directoryURL: directory)
    let context = SimulatorSessionContext(
      provider: .claude,
      sessionId: "session-1",
      projectPath: "/tmp/App",
      udid: "UDID",
      deviceName: nil,
      runtimeName: nil,
      isBooted: true,
      displayMode: "live"
    )

    try store.write(context)
    try store.remove(provider: .claude, sessionId: "session-1", projectPath: "/tmp/App")

    #expect(try store.context(provider: .claude, sessionId: "session-1", projectPath: "/tmp/App") == nil)
  }
}

private func temporarySimulatorContextDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-simulator-context-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("contexts", isDirectory: true)
}
