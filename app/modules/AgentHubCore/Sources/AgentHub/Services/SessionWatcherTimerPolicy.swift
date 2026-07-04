import Dispatch
import Foundation

struct SessionWatcherTimerPolicy {
  static let staleWatcherRecoveryInterval: TimeInterval = 5
  /// Floor for any scheduled interval. Overdue deadlines would otherwise
  /// return 0 and busy-loop the watcher's serial processing queue.
  static let minimumInterval: TimeInterval = 1.0
  static let timerLeeway: DispatchTimeInterval = .milliseconds(200)

  static func nextInterval(
    lastActivity: ActivityEntry?,
    currentStatus: SessionStatus,
    lastFileEventTime: Date,
    approvalTimeoutSeconds: Int,
    now: Date = Date()
  ) -> TimeInterval? {
    let staleRecoveryInterval: TimeInterval?
    if needsHealthCheck(for: currentStatus) {
      let sinceEvent = now.timeIntervalSince(lastFileEventTime)
      // Once overdue, the handler firing now performs the check — the next
      // one belongs a full period later, not immediately.
      staleRecoveryInterval = sinceEvent >= staleWatcherRecoveryInterval
        ? staleWatcherRecoveryInterval
        : staleWatcherRecoveryInterval - sinceEvent
    } else {
      staleRecoveryInterval = nil
    }

    let statusTransitionInterval = nextStatusTransitionInterval(
      lastActivity: lastActivity,
      currentStatus: currentStatus,
      approvalTimeoutSeconds: approvalTimeoutSeconds,
      now: now
    )

    switch (statusTransitionInterval, staleRecoveryInterval) {
    case (nil, nil):
      return nil
    case let (lhs?, nil):
      return max(lhs, minimumInterval)
    case let (nil, rhs?):
      return max(rhs, minimumInterval)
    case let (lhs?, rhs?):
      return max(min(lhs, rhs), minimumInterval)
    }
  }

  static func needsHealthCheck(for status: SessionStatus) -> Bool {
    switch status {
    case .idle, .waitingForUser:
      return false
    case .thinking, .executingTool, .awaitingApproval:
      return true
    }
  }

  private static func nextStatusTransitionInterval(
    lastActivity: ActivityEntry?,
    currentStatus: SessionStatus,
    approvalTimeoutSeconds: Int,
    now: Date
  ) -> TimeInterval? {
    guard let lastActivity else { return nil }

    let elapsed = now.timeIntervalSince(lastActivity.timestamp)

    switch lastActivity.type {
    case .toolUse(let name):
      switch currentStatus {
      case .executingTool:
        let deadline = name == "Task" ? 300.0 : Double(max(1, approvalTimeoutSeconds))
        return max(0, deadline - elapsed)
      case .awaitingApproval:
        return max(0, 300 - elapsed)
      default:
        return nil
      }

    case .toolResult, .userMessage:
      guard currentStatus == .thinking else { return nil }
      return max(0, 60 - elapsed)

    case .thinking:
      guard currentStatus == .thinking else { return nil }
      return max(0, 30 - elapsed)

    case .assistantMessage:
      return nil
    }
  }
}
