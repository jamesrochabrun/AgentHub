import Foundation
import Testing

@testable import AgentHubCore

@Suite("WebPreviewLocalhostReloadSignal")
struct WebPreviewLocalhostReloadSignalTests {

  @Test("Uses the latest successful code-changing tool result")
  func usesLatestSuccessfulCodeChangingToolResult() {
    let baselineDate = Date(timeIntervalSince1970: 1_000)
    let olderEditID = UUID()
    let bashID = UUID()
    let latestWriteID = UUID()

    let state = SessionMonitorState(
      recentActivities: [
        ActivityEntry(
          id: olderEditID,
          timestamp: baselineDate,
          type: .toolResult(name: "Edit", success: true),
          description: "Completed"
        ),
        ActivityEntry(
          id: bashID,
          timestamp: baselineDate.addingTimeInterval(5),
          type: .toolResult(name: "Bash", success: true),
          description: "Completed"
        ),
        ActivityEntry(
          id: latestWriteID,
          timestamp: baselineDate.addingTimeInterval(10),
          type: .toolResult(name: "Write", success: true),
          description: "Completed"
        )
      ]
    )

    let latestSignal = WebPreviewLocalhostReloadSignal.latest(from: state)

    #expect(latestSignal?.activityID == latestWriteID)
    #expect(latestSignal?.timestamp == baselineDate.addingTimeInterval(10))
  }

  @Test("Ignores failed and non-code tool results")
  func ignoresFailedAndNonCodeToolResults() {
    let baselineDate = Date(timeIntervalSince1970: 2_000)
    let state = SessionMonitorState(
      recentActivities: [
        ActivityEntry(
          timestamp: baselineDate,
          type: .toolResult(name: "Edit", success: false),
          description: "Error"
        ),
        ActivityEntry(
          timestamp: baselineDate.addingTimeInterval(5),
          type: .toolResult(name: "Bash", success: true),
          description: "Completed"
        )
      ]
    )

    #expect(WebPreviewLocalhostReloadSignal.latest(from: state) == nil)
  }

  @Test("Captures a historical signal as baseline without reloading")
  func capturesHistoricalSignalAsBaselineWithoutReload() {
    let activityID = UUID()
    let latestSignal = WebPreviewLocalhostReloadSignal(
      activityID: activityID,
      timestamp: Date(timeIntervalSince1970: 1_000)
    )

    let decision = WebPreviewLocalhostReloadSignal.decision(
      handledActivityID: nil,
      latestSignal: latestSignal,
      previewStartedAt: Date(timeIntervalSince1970: 2_000)
    )

    #expect(decision == .captureBaseline(activityID))
  }

  @Test("Reloads for a new code-change after preview start")
  func reloadsForNewCodeChangeAfterPreviewStart() {
    let activityID = UUID()
    let latestSignal = WebPreviewLocalhostReloadSignal(
      activityID: activityID,
      timestamp: Date(timeIntervalSince1970: 2_000)
    )

    let decision = WebPreviewLocalhostReloadSignal.decision(
      handledActivityID: nil,
      latestSignal: latestSignal,
      previewStartedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(decision == .reload(activityID))
  }

  @Test("Reloads when a newer code-change arrives after baseline")
  func reloadsWhenNewerCodeChangeArrivesAfterBaseline() {
    let previousID = UUID()
    let latestID = UUID()
    let latestSignal = WebPreviewLocalhostReloadSignal(
      activityID: latestID,
      timestamp: Date(timeIntervalSince1970: 2_000)
    )

    let decision = WebPreviewLocalhostReloadSignal.decision(
      handledActivityID: previousID,
      latestSignal: latestSignal,
      previewStartedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(decision == .reload(latestID))
  }
}
