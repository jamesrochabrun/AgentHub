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
