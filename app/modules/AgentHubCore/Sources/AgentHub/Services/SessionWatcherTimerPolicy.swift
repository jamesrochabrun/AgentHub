import Dispatch
import Foundation

struct SessionWatcherTimerPolicy {
  static let staleWatcherRecoveryInterval: TimeInterval = 5
  static let timerLeeway: DispatchTimeInterval = .milliseconds(200)

  static func nextInterval(
    lastActivity: ActivityEntry?,
    currentStatus: SessionStatus,
    lastFileEventTime: Date,
    approvalTimeoutSeconds: Int,
    now: Date = Date()
  ) -> TimeInterval? {
    let staleRecoveryInterval = needsHealthCheck(for: currentStatus)
      ? max(0, staleWatcherRecoveryInterval - now.timeIntervalSince(lastFileEventTime))
      : nil

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
      return lhs
    case let (nil, rhs?):
      return rhs
    case let (lhs?, rhs?):
      return min(lhs, rhs)
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
