//
//  GitHubCIFailureActionRouter.swift
//  AgentHub
//
//  Routes CI-failure notification taps into the monitoring UI
//

import Foundation

// MARK: - GitHubCIFailureActionRequest

public struct GitHubCIFailureActionRequest: Identifiable, Equatable, Sendable {

  public enum Action: Equatable, Sendable {
    /// Default notification tap: select the session and open its GitHub panel.
    case openGitHubPanel
    /// "Fix CI" action button: fetch the failure and inject a fix prompt into
    /// the session's agent terminal.
    case fixCI
  }

  public let id: UUID
  public let payload: GitHubCIFailureNotificationPayload
  public let action: Action

  public init(
    id: UUID = UUID(),
    payload: GitHubCIFailureNotificationPayload,
    action: Action
  ) {
    self.id = id
    self.payload = payload
    self.action = action
  }
}

// MARK: - GitHubCIFailureActionRouter

/// Publishes pending CI-failure notification actions for the monitoring panel
/// to consume, mirroring `GlobalSessionSelectionRouter`'s request/consume flow.
@MainActor
@Observable
public final class GitHubCIFailureActionRouter {
  public private(set) var pendingRequest: GitHubCIFailureActionRequest?

  public init() {}

  public func request(
    payload: GitHubCIFailureNotificationPayload,
    action: GitHubCIFailureActionRequest.Action
  ) {
    pendingRequest = GitHubCIFailureActionRequest(payload: payload, action: action)
  }

  public func markConsumed(_ request: GitHubCIFailureActionRequest) {
    guard pendingRequest?.id == request.id else { return }
    pendingRequest = nil
  }
}
