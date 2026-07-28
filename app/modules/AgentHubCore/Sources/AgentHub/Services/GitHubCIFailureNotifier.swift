//
//  GitHubCIFailureNotifier.swift
//  AgentHub
//
//  Posts macOS notifications when an observed PR's CI starts failing
//

import AgentHubGitHub
import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

// MARK: - GitHubCIFailureNotification (category)

/// Identifiers for the CI-failure notification category and its actions.
/// The app delegate registers the category at launch and matches these
/// identifiers when handling notification responses.
public enum GitHubCIFailureNotification {
  public static let categoryIdentifier = "com.agenthub.notification.ciFailure"
  public static let fixActionIdentifier = "com.agenthub.notification.ciFailure.fixAction"

  public static func category() -> UNNotificationCategory {
    let fixAction = UNNotificationAction(
      identifier: fixActionIdentifier,
      title: "Fix CI",
      options: [.foreground]
    )
    return UNNotificationCategory(
      identifier: categoryIdentifier,
      actions: [fixAction],
      intentIdentifiers: []
    )
  }
}

// MARK: - GitHubCIFailureSessionContext

/// The session a CI snapshot was observed for — supplied by the UI surface
/// that owns the observation subscription, since snapshots themselves only
/// know the repository/branch target.
public struct GitHubCIFailureSessionContext: Equatable, Sendable {
  public let sessionId: String
  public let providerKind: SessionProviderKind
  public let projectPath: String
  public let branchName: String?

  public init(
    sessionId: String,
    providerKind: SessionProviderKind,
    projectPath: String,
    branchName: String?
  ) {
    self.sessionId = sessionId
    self.providerKind = providerKind
    self.projectPath = projectPath
    self.branchName = branchName
  }
}

// MARK: - GitHubCIFailureNotifierProtocol

public protocol GitHubCIFailureNotifierProtocol: AnyObject {
  /// Evaluates an observation snapshot for a session and posts a notification
  /// when its PR's CI is newly failing. Deduplicates per PR head commit, so
  /// multiple surfaces observing the same session can all feed snapshots.
  @MainActor
  func evaluate(snapshot: GitHubPRObservationSnapshot, context: GitHubCIFailureSessionContext)
}

// MARK: - GitHubCIFailureNotifier

@MainActor
public final class GitHubCIFailureNotifier: GitHubCIFailureNotifierProtocol {

  public typealias SendNotification = @Sendable (UNNotificationRequest) async -> Void

  /// Caps how many failed checks ride along in the notification payload.
  private static let maximumPayloadChecks = 5

  private var notifiedFailureKeys: Set<String> = []
  private let isEnabled: () -> Bool
  private let sendNotification: SendNotification

  public init(
    isEnabled: (() -> Bool)? = nil,
    sendNotification: SendNotification? = nil
  ) {
    self.isEnabled = isEnabled ?? {
      let defaults = UserDefaults.standard
      let pushEnabled = defaults.object(forKey: AgentHubDefaults.pushNotificationsEnabled) as? Bool ?? true
      let ciEnabled = defaults.object(forKey: AgentHubDefaults.ciFailureNotificationsEnabled) as? Bool ?? true
      return pushEnabled && ciEnabled
    }
    self.sendNotification = sendNotification ?? { request in
      #if canImport(AppKit)
      if UserDefaults.standard.object(forKey: AgentHubDefaults.notificationSoundsEnabled) as? Bool ?? true {
        await MainActor.run { NSSound.beep() }
      }
      #endif
      try? await UNUserNotificationCenter.current().add(request)
    }
  }

  public func evaluate(
    snapshot: GitHubPRObservationSnapshot,
    context: GitHubCIFailureSessionContext
  ) {
    guard isEnabled() else { return }
    // Only act on complete, fresh refreshes — refreshing/error states rebroadcast
    // carried-over data and must not trigger (or re-trigger) notifications.
    guard snapshot.state == .ready, !snapshot.isStale else { return }
    guard let pullRequest = snapshot.pullRequest, pullRequest.stateKind == .open else { return }
    guard snapshot.ciSummary.failed > 0 else { return }
    let failedChecks = snapshot.checks.filter { $0.ciStatus == .failure }
    guard !failedChecks.isEmpty else { return }

    let failureKey = [
      context.projectPath,
      "\(pullRequest.number)",
      pullRequest.headRefOid ?? "no-head"
    ].joined(separator: "|")
    guard !notifiedFailureKeys.contains(failureKey) else { return }
    notifiedFailureKeys.insert(failureKey)

    let payload = GitHubCIFailureNotificationPayload(
      sessionId: context.sessionId,
      providerKindRawValue: context.providerKind.rawValue,
      projectPath: context.projectPath,
      branchName: context.branchName ?? pullRequest.headRefName,
      prNumber: pullRequest.number,
      prTitle: pullRequest.title,
      failedChecks: failedChecks.prefix(Self.maximumPayloadChecks).map {
        GitHubCIFailureNotificationPayload.FailedCheck(
          name: $0.name,
          workflowName: $0.workflowName,
          detailsUrl: $0.detailsUrl
        )
      }
    )

    let content = UNMutableNotificationContent()
    content.title = "CI failing on PR #\(pullRequest.number)"
    content.subtitle = URL(fileURLWithPath: context.projectPath).lastPathComponent
    content.body = Self.body(failedCheckNames: failedChecks.map(\.name))
    content.sound = .none
    content.categoryIdentifier = GitHubCIFailureNotification.categoryIdentifier
    content.userInfo = payload.userInfo

    let request = UNNotificationRequest(
      identifier: "ci-failure-\(failureKey)",
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    )
    let sendNotification = sendNotification
    Task(priority: .userInitiated) {
      await sendNotification(request)
    }
  }

  nonisolated static func body(failedCheckNames: [String]) -> String {
    let shown = failedCheckNames.prefix(3).joined(separator: ", ")
    let remainder = failedCheckNames.count - min(failedCheckNames.count, 3)
    return remainder > 0 ? "\(shown) and \(remainder) more failed" : "\(shown) failed"
  }
}
