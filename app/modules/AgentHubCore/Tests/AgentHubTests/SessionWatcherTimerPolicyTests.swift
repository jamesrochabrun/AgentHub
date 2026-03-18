import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionWatcherTimerPolicy")
struct SessionWatcherTimerPolicyTests {

  @Test("Does not schedule timers for waiting-for-user sessions")
  func doesNotScheduleWaitingForUserTimers() {
    let now = Date(timeIntervalSince1970: 10_000)
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-20),
      type: .assistantMessage,
      description: "Ready"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .waitingForUser,
      lastFileEventTime: now.addingTimeInterval(-1),
      approvalTimeoutSeconds: 5,
      now: now
    )

    #expect(interval == nil)
  }

  @Test("Does not schedule timers for idle sessions")
  func doesNotScheduleIdleTimers() {
    let now = Date(timeIntervalSince1970: 10_000)
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-120),
      type: .assistantMessage,
      description: "Done"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .idle,
      lastFileEventTime: now.addingTimeInterval(-20),
      approvalTimeoutSeconds: 5,
      now: now
    )

    #expect(interval == nil)
  }

  @Test("Uses approval timeout when it happens before stale recovery")
  func usesApprovalTimeoutWhenSooner() {
    let now = Date(timeIntervalSince1970: 10_000)
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-1),
      type: .toolUse(name: "Bash"),
      description: "ls"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .executingTool(name: "Bash"),
      lastFileEventTime: now,
      approvalTimeoutSeconds: 2,
      now: now
    )

    #expect(interval == 1)
  }

  @Test("Uses stale recovery when the status transition is farther away")
  func usesStaleRecoveryWhenSooner() {
    let now = Date(timeIntervalSince1970: 10_000)
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-1),
      type: .toolResult(name: "Read", success: true),
      description: "Completed"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .thinking,
      lastFileEventTime: now.addingTimeInterval(-2),
      approvalTimeoutSeconds: 5,
      now: now
    )

    #expect(interval == 3)
  }
}
