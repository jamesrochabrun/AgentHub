//
//  GlobalSessionControlPanelModels.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation

// MARK: - GlobalSessionControlPanelGitHubState

public struct GlobalSessionControlPanelGitHubState: Equatable, Sendable {
  public let hasPullRequest: Bool
  public let ciStatus: CIStatus
  public let isRefreshing: Bool

  public init(
    hasPullRequest: Bool,
    ciStatus: CIStatus,
    isRefreshing: Bool = false
  ) {
    self.hasPullRequest = hasPullRequest
    self.ciStatus = ciStatus
    self.isRefreshing = isRefreshing
  }
}

// MARK: - GlobalSessionControlPanelAttention

public enum GlobalSessionControlPanelAttention: Int, Equatable, Sendable {
  case awaitingApproval = 0
  case ciFailure = 1
  case working = 2
  case pending = 3
  case ready = 4
  case idle = 5
}

// MARK: - GlobalSessionControlPanelItem

public struct GlobalSessionControlPanelItem: Identifiable, Equatable, Sendable {
  public let id: String
  public let session: CLISession
  public let providerKind: SessionProviderKind
  public let timestamp: Date
  public let isPending: Bool
  public let status: SessionStatus?
  public let linkedPullRequestNumber: Int?
  public let customName: String?
  public let gitHubState: GlobalSessionControlPanelGitHubState?

  public init(
    id: String,
    session: CLISession,
    providerKind: SessionProviderKind,
    timestamp: Date,
    isPending: Bool,
    status: SessionStatus?,
    linkedPullRequestNumber: Int?,
    customName: String?,
    gitHubState: GlobalSessionControlPanelGitHubState? = nil
  ) {
    self.id = id
    self.session = session
    self.providerKind = providerKind
    self.timestamp = timestamp
    self.isPending = isPending
    self.status = status
    self.linkedPullRequestNumber = linkedPullRequestNumber
    self.customName = customName
    self.gitHubState = gitHubState
  }

  public var displayName: String {
    customName ?? session.displayName
  }

  public var attention: GlobalSessionControlPanelAttention {
    if let status {
      switch status {
      case .awaitingApproval:
        return .awaitingApproval
      case .thinking, .executingTool:
        return .working
      case .waitingForUser:
        if gitHubState?.ciStatus == .failure { return .ciFailure }
        if gitHubState?.ciStatus == .pending { return .pending }
        return .ready
      case .idle:
        break
      }
    }

    if gitHubState?.ciStatus == .failure { return .ciFailure }
    if isPending || gitHubState?.ciStatus == .pending { return .pending }
    return .idle
  }
}

// MARK: - GlobalSessionControlPanelSnapshotBuilder

public enum GlobalSessionControlPanelSnapshotBuilder {
  public static func makeItems(
    claudePending: [PendingHubSession],
    codexPending: [PendingHubSession],
    claudeMonitored: [(session: CLISession, state: SessionMonitorState?)],
    codexMonitored: [(session: CLISession, state: SessionMonitorState?)],
    claudeCustomNames: [String: String],
    codexCustomNames: [String: String],
    gitHubStates: [String: GlobalSessionControlPanelGitHubState]
  ) -> [GlobalSessionControlPanelItem] {
    var items: [GlobalSessionControlPanelItem] = []

    for pending in claudePending {
      items.append(pendingItem(
        pending,
        providerKind: .claude,
        gitHubStates: gitHubStates
      ))
    }

    for pending in codexPending {
      items.append(pendingItem(
        pending,
        providerKind: .codex,
        gitHubStates: gitHubStates
      ))
    }

    for item in claudeMonitored {
      items.append(monitoredItem(
        session: item.session,
        state: item.state,
        providerKind: .claude,
        customName: claudeCustomNames[item.session.id],
        gitHubStates: gitHubStates
      ))
    }

    for item in codexMonitored {
      items.append(monitoredItem(
        session: item.session,
        state: item.state,
        providerKind: .codex,
        customName: codexCustomNames[item.session.id],
        gitHubStates: gitHubStates
      ))
    }

    return sorted(items)
  }

  public static func sorted(_ items: [GlobalSessionControlPanelItem]) -> [GlobalSessionControlPanelItem] {
    items.sorted { lhs, rhs in
      if lhs.attention != rhs.attention {
        return lhs.attention.rawValue < rhs.attention.rawValue
      }
      if lhs.timestamp != rhs.timestamp {
        return lhs.timestamp > rhs.timestamp
      }
      if lhs.providerKind != rhs.providerKind {
        return lhs.providerKind.rawValue < rhs.providerKind.rawValue
      }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
  }

  public static func itemId(providerKind: SessionProviderKind, sessionId: String) -> String {
    GlobalSessionSelectionRequest.itemId(providerKind: providerKind, sessionId: sessionId)
  }

  public static func pendingItemId(providerKind: SessionProviderKind, pendingId: UUID) -> String {
    "pending-\(providerKind.rawValue.lowercased())-\(pendingId.uuidString)"
  }

  private static func pendingItem(
    _ pending: PendingHubSession,
    providerKind: SessionProviderKind,
    gitHubStates: [String: GlobalSessionControlPanelGitHubState]
  ) -> GlobalSessionControlPanelItem {
    let session = pending.placeholderSession
    let id = pendingItemId(providerKind: providerKind, pendingId: pending.id)
    return GlobalSessionControlPanelItem(
      id: id,
      session: session,
      providerKind: providerKind,
      timestamp: pending.startedAt,
      isPending: true,
      status: nil,
      linkedPullRequestNumber: nil,
      customName: nil,
      gitHubState: gitHubStates[id]
    )
  }

  private static func monitoredItem(
    session: CLISession,
    state: SessionMonitorState?,
    providerKind: SessionProviderKind,
    customName: String?,
    gitHubStates: [String: GlobalSessionControlPanelGitHubState]
  ) -> GlobalSessionControlPanelItem {
    let id = itemId(providerKind: providerKind, sessionId: session.id)
    return GlobalSessionControlPanelItem(
      id: id,
      session: session,
      providerKind: providerKind,
      timestamp: session.lastActivityAt,
      isPending: false,
      status: state?.status,
      linkedPullRequestNumber: latestPullRequestNumber(in: state?.detectedResourceLinks ?? []),
      customName: customName,
      gitHubState: gitHubStates[id]
    )
  }

  private static func latestPullRequestNumber(in links: [ResourceLink]) -> Int? {
    GitHubPullRequestURLReference.latestNumber(in: links.map(\.url))
  }
}
