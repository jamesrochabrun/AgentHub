import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionFileWatcher approval modes")
struct SessionFileWatcherApprovalModeTests {

  @Test("Auto mode suppresses timeout-inferred approval state")
  func autoModeSuppressesTimeoutInferredApprovalState() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }

    try fixture.writeSessionFile(lines: [
      try Self.toolUseLine(
        id: "tu-auto",
        toolName: "Edit",
        timestamp: Date().addingTimeInterval(-10)
      )
    ])
    try fixture.writeSidecarLines([
      [
        "event": "observed",
        "toolName": "Edit",
        "toolUseId": "tu-auto",
        "timestamp": Self.timestamp(Date()),
        "permissionMode": "auto",
        "input": ["file_path": "/tmp/x.swift", "old_string": "a", "new_string": "b"],
      ]
    ])

    let watcher = fixture.makeWatcher()
    await watcher.setApprovalTimeout(1)
    await watcher.startMonitoring(
      sessionId: fixture.sessionId,
      projectPath: fixture.projectPath,
      sessionFilePath: fixture.sessionFileURL.path
    )

    let state = await watcher.getState(sessionId: fixture.sessionId)
    #expect(state?.status == .executingTool(name: "Edit"))
    #expect(state?.pendingToolUse == nil)
    await watcher.stopMonitoring(sessionId: fixture.sessionId)
  }

  @Test("Default mode still surfaces timeout-inferred approval state")
  func defaultModeSurfacesTimeoutInferredApprovalState() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }

    try fixture.writeSessionFile(lines: [
      try Self.toolUseLine(
        id: "tu-default",
        toolName: "Edit",
        timestamp: Date().addingTimeInterval(-10)
      )
    ])

    let watcher = fixture.makeWatcher()
    await watcher.setApprovalTimeout(1)
    await watcher.startMonitoring(
      sessionId: fixture.sessionId,
      projectPath: fixture.projectPath,
      sessionFilePath: fixture.sessionFileURL.path
    )

    let state = await watcher.getState(sessionId: fixture.sessionId)
    #expect(state?.status == .awaitingApproval(tool: "Edit"))
    #expect(state?.pendingToolUse?.toolUseId == "tu-default")
    await watcher.stopMonitoring(sessionId: fixture.sessionId)
  }

  @Test("PermissionRequest sidecar event surfaces real approval")
  func permissionRequestSidecarEventSurfacesRealApproval() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }

    try fixture.writeSessionFile(lines: [])
    try fixture.writeSidecarLines([
      [
        "event": "pending",
        "toolName": "Bash",
        "toolUseId": "tu-request",
        "timestamp": Self.timestamp(Date()),
        "permissionMode": "default",
        "input": ["command": "npm test"],
      ]
    ])

    let watcher = fixture.makeWatcher()
    await watcher.startMonitoring(
      sessionId: fixture.sessionId,
      projectPath: fixture.projectPath,
      sessionFilePath: fixture.sessionFileURL.path
    )

    let state = await watcher.getState(sessionId: fixture.sessionId)
    #expect(state?.status == .awaitingApproval(tool: "Bash"))
    #expect(state?.pendingToolUse?.toolUseId == "tu-request")
    await watcher.stopMonitoring(sessionId: fixture.sessionId)
  }

  @Test("Auto mode suppresses stale pending sidecar approval")
  func autoModeSuppressesStalePendingSidecarApproval() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }

    try fixture.writeSessionFile(lines: [])
    try fixture.writeSidecarLines([
      [
        "event": "pending",
        "toolName": "Bash",
        "toolUseId": "tu-auto-request",
        "timestamp": Self.timestamp(Date()),
        "permissionMode": "auto",
        "input": ["command": "npm test"],
      ]
    ])

    let watcher = fixture.makeWatcher()
    await watcher.startMonitoring(
      sessionId: fixture.sessionId,
      projectPath: fixture.projectPath,
      sessionFilePath: fixture.sessionFileURL.path
    )

    let state = await watcher.getState(sessionId: fixture.sessionId)
    #expect(state?.status == .idle)
    #expect(state?.pendingToolUse == nil)
    await watcher.stopMonitoring(sessionId: fixture.sessionId)
  }

  private final class Fixture {
    let baseURL: URL
    let projectURL: URL
    let sessionFileURL: URL
    let approvalsDirectory: URL
    let sessionId = "session-approval-mode"

    var projectPath: String { projectURL.path }

    init() throws {
      baseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agenthub-approval-mode-\(UUID().uuidString)", isDirectory: true)
      projectURL = baseURL.appendingPathComponent("project", isDirectory: true)
      approvalsDirectory = baseURL.appendingPathComponent("approvals", isDirectory: true)
      sessionFileURL = baseURL.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
      try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: approvalsDirectory, withIntermediateDirectories: true)
    }

    func teardown() {
      try? FileManager.default.removeItem(at: baseURL)
    }

    func makeWatcher() -> SessionFileWatcher {
      SessionFileWatcher(
        claudePath: baseURL.path,
        approvalNotificationService: NoOpApprovalNotificationService(),
        hookSidecarWatcher: ClaudeHookSidecarWatcher(approvalsDirectory: approvalsDirectory)
      )
    }

    func writeSessionFile(lines: [String]) throws {
      try lines.joined(separator: "\n").write(to: sessionFileURL, atomically: true, encoding: .utf8)
    }

    func writeSidecarLines(_ objects: [[String: Any]]) throws {
      let file = approvalsDirectory.appendingPathComponent("\(sessionId).jsonl")
      var data = Data()
      for object in objects {
        data.append(try JSONSerialization.data(withJSONObject: object))
        data.append(0x0A)
      }
      try data.write(to: file)
    }
  }

  private static func toolUseLine(id: String, toolName: String, timestamp: Date) throws -> String {
    let object: [String: Any] = [
      "type": "assistant",
      "timestamp": Self.timestamp(timestamp),
      "message": [
        "role": "assistant",
        "model": "claude-sonnet-4-5",
        "content": [
          [
            "type": "tool_use",
            "id": id,
            "name": toolName,
            "input": ["file_path": "/tmp/x.swift", "old_string": "a", "new_string": "b"],
          ]
        ],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
