//
//  WorktreeReadyNotificationService.swift
//  AgentHub
//

import Foundation
import UserNotifications

// MARK: - WorktreeReadyNotificationServiceProtocol

/// Posts a macOS notification when all in-flight worktree creations have
/// finished. Mirrors `ApprovalNotificationService` but is provider-injected
/// (not a singleton) so it can be mocked in tests.
public protocol WorktreeReadyNotificationServiceProtocol: AnyObject, Sendable {
  @discardableResult
  func requestPermission() async -> Bool
  /// Posts a "Worktrees ready" notification listing the freshly created
  /// branches. No-op (silent) when push notifications are disabled.
  func notifyReady(branchNames: [String])
}

// MARK: - WorktreeReadyNotificationService

public final class WorktreeReadyNotificationService: WorktreeReadyNotificationServiceProtocol {

  public init() {}

  @discardableResult
  public func requestPermission() async -> Bool {
    do {
      return try await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .sound])
    } catch {
      return false
    }
  }

  public func notifyReady(branchNames: [String]) {
    guard pushNotificationsEnabled, !branchNames.isEmpty else { return }

    let content = UNMutableNotificationContent()
    content.title = Self.notificationTitle(branchCount: branchNames.count)
    content.body = Self.notificationBody(branchNames: branchNames)
    content.sound = .none // The Glass success sound is played separately by the coordinator.

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    let request = UNNotificationRequest(
      identifier: "worktree-ready-\(branchNames.joined(separator: ","))",
      content: content,
      trigger: trigger
    )

    Task(priority: .userInitiated) {
      do {
        try await UNUserNotificationCenter.current().add(request)
      } catch {
        // Best-effort enhancement — silently ignore failures.
      }
    }
  }

  // MARK: - Message construction (pure, unit-testable)

  static func notificationTitle(branchCount: Int) -> String {
    branchCount == 1 ? "Worktree ready" : "Worktrees ready"
  }

  static func notificationBody(branchNames: [String]) -> String {
    switch branchNames.count {
    case 0:
      return ""
    case 1:
      return "\(branchNames[0]) is ready."
    default:
      return "\(branchNames.count) worktrees are ready: \(branchNames.joined(separator: ", "))."
    }
  }

  // MARK: - Private

  private var pushNotificationsEnabled: Bool {
    UserDefaults.standard.object(forKey: AgentHubDefaults.pushNotificationsEnabled) as? Bool ?? true
  }
}
