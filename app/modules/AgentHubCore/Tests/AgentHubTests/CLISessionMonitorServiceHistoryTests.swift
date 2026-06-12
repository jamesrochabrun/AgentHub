import Foundation
import Testing

@testable import AgentHubCore

@Suite("CLISessionMonitorService history summaries")
struct CLISessionMonitorServiceHistoryTests {

  @Test("Accumulates incremental entries while preserving first and last messages")
  func accumulatesIncrementalEntries() throws {
    var summaries: [String: CLISessionMonitorService.HistorySessionSummary] = [:]
    let monitoredPaths: Set<String> = ["/repo"]

    CLISessionMonitorService.accumulateHistoryEntries(
      [
        try historyEntry(
          display: "First prompt",
          timestamp: 1_000,
          project: "/repo",
          sessionId: "session-1"
        ),
        try historyEntry(
          display: "Second prompt",
          timestamp: 2_000,
          project: "/repo",
          sessionId: "session-1"
        )
      ],
      filteredBy: monitoredPaths,
      into: &summaries
    )

    CLISessionMonitorService.accumulateHistoryEntries(
      [
        try historyEntry(
          display: "Third prompt",
          timestamp: 3_000,
          project: "/repo",
          sessionId: "session-1"
        )
      ],
      filteredBy: monitoredPaths,
      into: &summaries
    )

    let summary = try #require(summaries["session-1"])
    #expect(summary.project == "/repo")
    #expect(summary.firstDisplay == "First prompt")
    #expect(summary.lastDisplay == "Third prompt")
    #expect(summary.messageCount == 3)
    #expect(summary.firstTimestamp == 1_000)
    #expect(summary.lastTimestamp == 3_000)
  }

  @Test("Filters entries outside the monitored path set")
  func filtersEntriesOutsideMonitoredPathSet() throws {
    var summaries: [String: CLISessionMonitorService.HistorySessionSummary] = [:]

    CLISessionMonitorService.accumulateHistoryEntries(
      [
        try historyEntry(
          display: "Keep me",
          timestamp: 1_000,
          project: "/repo/subdir",
          sessionId: "session-in"
        ),
        try historyEntry(
          display: "Ignore me",
          timestamp: 2_000,
          project: "/other",
          sessionId: "session-out"
        )
      ],
      filteredBy: ["/repo"],
      into: &summaries
    )

    #expect(summaries.keys.sorted() == ["session-in"])
    #expect(CLISessionMonitorService.matchesMonitoredPath("/repo/subdir", monitoredPaths: ["/repo"]))
    #expect(!CLISessionMonitorService.matchesMonitoredPath("/other", monitoredPaths: ["/repo"]))
  }

  @Test("Loads latest Claude sessions for a worktree import page")
  func loadsLatestClaudeWorktreeImportPage() async throws {
    let root = try temporaryDirectory(name: "claude_import")
    defer { try? FileManager.default.removeItem(at: root) }

    let parentPath = root.appending(path: "Project").path
    let worktreePath = root.appending(path: "Project-feature").path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)

    let service = CLISessionMonitorService(claudeDataPath: root.path)
    await service.registerWorktree(
      WorktreeBranch(name: "feature/import", path: worktreePath, isWorktree: true),
      parentRepositoryPath: parentPath
    )

    try writeClaudeHistory(
      root: root,
      entries: [
        ("session-1", worktreePath, 1_000, "oldest"),
        ("session-2", worktreePath + "/app", 2_000, "nested"),
        ("session-3", worktreePath, 3_000, "third"),
        ("session-4", worktreePath, 4_000, "fourth"),
        ("session-5", worktreePath, 5_000, "excluded"),
        ("session-out", root.appending(path: "Other").path, 6_000, "outside"),
      ]
    )

    let page = await service.loadLatestSessions(
      inWorktreePath: worktreePath,
      excludingSessionIds: ["session-5"],
      limit: 3
    )

    #expect(page.sessions.map(\.id) == ["session-4", "session-3", "session-2"])
    let allFromWorktree = page.sessions.allSatisfy(\.isWorktree)
    #expect(allFromWorktree)
    #expect(page.hasMore)
  }
}

private func historyEntry(
  display: String,
  timestamp: Int64,
  project: String,
  sessionId: String
) throws -> HistoryEntry {
  let json = """
  {"display":"\(display)","timestamp":\(timestamp),"project":"\(project)","sessionId":"\(sessionId)"}
  """
  let data = try #require(json.data(using: .utf8))
  return try JSONDecoder().decode(HistoryEntry.self, from: data)
}

private func writeClaudeHistory(
  root: URL,
  entries: [(sessionId: String, project: String, timestamp: Int64, display: String)]
) throws {
  let historyLines = entries.map { entry in
    """
    {"display":"\(entry.display)","timestamp":\(entry.timestamp),"project":"\(entry.project)","sessionId":"\(entry.sessionId)"}
    """
  }
  try historyLines.joined(separator: "\n").write(
    to: root.appending(path: "history.jsonl"),
    atomically: true,
    encoding: .utf8
  )

  for entry in entries {
    let projectDirectory = root
      .appending(path: "projects")
      .appending(path: entry.project.claudeProjectPathEncoded)
    try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    try claudeSessionLine(
      sessionId: entry.sessionId,
      cwd: entry.project,
      message: entry.display
    )
    .write(
      to: projectDirectory.appending(path: "\(entry.sessionId).jsonl"),
      atomically: true,
      encoding: .utf8
    )
  }
}

private func claudeSessionLine(sessionId: String, cwd: String, message: String) -> String {
  """
  {"sessionId":"\(sessionId)","cwd":"\(cwd)","gitBranch":"feature/import","slug":"\(sessionId)-slug","type":"user","timestamp":"2026-05-05T12:00:00.000Z","message":{"role":"user","content":"\(message)"}}

  """
}

private func temporaryDirectory(name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "\(name)_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
