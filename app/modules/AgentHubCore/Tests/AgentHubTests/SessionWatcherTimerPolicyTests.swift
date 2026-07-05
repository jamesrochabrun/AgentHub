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

  @Test("Floors an executing tool past its approval deadline instead of returning 0")
  func floorsOverdueToolDeadline() {
    let now = Date(timeIntervalSince1970: 10_000)
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-120),
      type: .toolUse(name: "Bash"),
      description: "ls"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .executingTool(name: "Bash"),
      lastFileEventTime: now,
      approvalTimeoutSeconds: 60,
      now: now
    )

    #expect(interval == SessionWatcherTimerPolicy.minimumInterval)
  }

  @Test("Floors a Task tool past its 300s deadline instead of returning 0")
  func floorsOverdueTaskDeadline() {
    let now = Date(timeIntervalSince1970: 10_000)
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-400),
      type: .toolUse(name: "Task"),
      description: "Subagent"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .executingTool(name: "Task"),
      lastFileEventTime: now,
      approvalTimeoutSeconds: 60,
      now: now
    )

    #expect(interval == SessionWatcherTimerPolicy.minimumInterval)
  }

  @Test("Floors an approval past its 300s deadline instead of returning 0")
  func floorsOverdueApprovalDeadline() {
    let now = Date(timeIntervalSince1970: 10_000)
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-301),
      type: .toolUse(name: "Edit"),
      description: "Edit file"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .awaitingApproval(tool: "Edit"),
      lastFileEventTime: now,
      approvalTimeoutSeconds: 60,
      now: now
    )

    #expect(interval == SessionWatcherTimerPolicy.minimumInterval)
  }

  @Test("Overdue health check waits a full recovery period instead of returning 0")
  func overdueHealthCheckWaitsFullPeriod() {
    let now = Date(timeIntervalSince1970: 10_000)

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: nil,
      currentStatus: .thinking,
      lastFileEventTime: now.addingTimeInterval(-10),
      approvalTimeoutSeconds: 60,
      now: now
    )

    #expect(interval == SessionWatcherTimerPolicy.staleWatcherRecoveryInterval)
  }

  @Test("Upcoming health check returns the remaining time when no transition is sooner")
  func upcomingHealthCheckReturnsRemainder() {
    let now = Date(timeIntervalSince1970: 10_000)

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: nil,
      currentStatus: .thinking,
      lastFileEventTime: now.addingTimeInterval(-2),
      approvalTimeoutSeconds: 60,
      now: now
    )

    #expect(interval == 3)
  }

  @Test("Sub-deadline transition sooner than the health check passes through unclamped")
  func subDeadlineTransitionUnclamped() {
    let now = Date(timeIntervalSince1970: 10_000)
    // 3s to the tool deadline, 5s to the next health check: the transition
    // term wins and is not distorted by the minimum-interval floor.
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-57),
      type: .toolUse(name: "Bash"),
      description: "ls"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .executingTool(name: "Bash"),
      lastFileEventTime: now,
      approvalTimeoutSeconds: 60,
      now: now
    )

    #expect(interval == 3)
  }

  @Test("Distant transition deadline is bounded by the health-check cadence")
  func distantTransitionBoundedByHealthCheck() {
    let now = Date(timeIntervalSince1970: 10_000)
    // 50s to the tool deadline, but a health-checked status never waits
    // longer than the stale-recovery interval.
    let lastActivity = ActivityEntry(
      timestamp: now.addingTimeInterval(-10),
      type: .toolUse(name: "Bash"),
      description: "ls"
    )

    let interval = SessionWatcherTimerPolicy.nextInterval(
      lastActivity: lastActivity,
      currentStatus: .executingTool(name: "Bash"),
      lastFileEventTime: now,
      approvalTimeoutSeconds: 60,
      now: now
    )

    #expect(interval == SessionWatcherTimerPolicy.staleWatcherRecoveryInterval)
  }
}
