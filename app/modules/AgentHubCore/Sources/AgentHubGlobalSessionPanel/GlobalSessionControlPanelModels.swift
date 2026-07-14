//
//  GlobalSessionControlPanelModels.swift
//  AgentHub
//

import Foundation
import AgentHubCore
import AgentHubGitHub

// MARK: - GlobalSessionControlPanelGitHubState

public struct GlobalSessionControlPanelGitHubState: Equatable, Sendable {
  public let hasPullRequest: Bool
  public let pullRequestNumber: Int?
  public let pullRequestState: GitHubPullRequestState?
  public let pullRequestMergeability: GitHubMergeability?
  public let ciStatus: CIStatus
  public let blockers: Set<GitHubPRBlocker>
  public let isRefreshing: Bool

  public init(
    hasPullRequest: Bool,
    ciStatus: CIStatus,
    isRefreshing: Bool = false,
    pullRequestNumber: Int? = nil,
    pullRequestState: GitHubPullRequestState? = nil,
    pullRequestMergeability: GitHubMergeability? = nil,
    blockers: Set<GitHubPRBlocker> = []
  ) {
    self.hasPullRequest = hasPullRequest
    self.pullRequestNumber = pullRequestNumber
    self.pullRequestState = pullRequestState
    self.pullRequestMergeability = pullRequestMergeability
    self.ciStatus = ciStatus
    var resolvedBlockers = blockers
    if ciStatus == .failure {
      resolvedBlockers.insert(.ciFailure)
    }
    if pullRequestMergeability == .conflicting {
      resolvedBlockers.insert(.mergeConflict)
    }
    self.blockers = resolvedBlockers
    self.isRefreshing = isRefreshing
  }
}

// MARK: - GlobalSessionControlPanelAttention

public enum GlobalSessionControlPanelAttention: Int, Equatable, Sendable {
  case awaitingApproval = 0
  case gitHubBlocked = 1
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
  public let linkedPullRequests: [GitHubPullRequestURLReference]
  public let customName: String?
  public let gitHubState: GlobalSessionControlPanelGitHubState?

  public init(
    id: String,
    session: CLISession,
    providerKind: SessionProviderKind,
    timestamp: Date,
    isPending: Bool,
    status: SessionStatus?,
    linkedPullRequests: [GitHubPullRequestURLReference],
    customName: String?,
    gitHubState: GlobalSessionControlPanelGitHubState? = nil
  ) {
    self.id = id
    self.session = session
    self.providerKind = providerKind
    self.timestamp = timestamp
    self.isPending = isPending
    self.status = status
    self.linkedPullRequests = linkedPullRequests
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
        if gitHubState?.blockers.isEmpty == false { return .gitHubBlocked }
        if gitHubState?.ciStatus == .pending { return .pending }
        return .ready
      case .idle:
        break
      }
    }

    if gitHubState?.blockers.isEmpty == false { return .gitHubBlocked }
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
      linkedPullRequests: [],
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
      linkedPullRequests: pullRequestReferences(in: state?.detectedResourceLinks ?? []),
      customName: customName,
      gitHubState: gitHubStates[id]
    )
  }

  private static func pullRequestReferences(in links: [ResourceLink]) -> [GitHubPullRequestURLReference] {
    links.compactMap { GitHubPullRequestURLReference(urlString: $0.url) }
  }
}

// MARK: - GlobalSessionCleanupSuggestion

public struct GlobalSessionCleanupSuggestion: Identifiable, Equatable, Sendable {
  public let worktreePath: String
  public let worktreeName: String
  public let sessionIDs: [String]
  public let providerKinds: [SessionProviderKind]
  public let mergedPullRequestNumbers: [Int]

  public var id: String { worktreePath }

  public init(
    worktreePath: String,
    worktreeName: String,
    sessionIDs: [String],
    providerKinds: [SessionProviderKind],
    mergedPullRequestNumbers: [Int]
  ) {
    self.worktreePath = worktreePath
    self.worktreeName = worktreeName
    self.sessionIDs = sessionIDs
    self.providerKinds = providerKinds
    self.mergedPullRequestNumbers = mergedPullRequestNumbers
  }
}

// MARK: - GlobalSessionCleanupSuggestionBuilder

public enum GlobalSessionCleanupSuggestionBuilder {
  public static func makeSuggestions(
    items: [GlobalSessionControlPanelItem],
    repositories: [SelectedRepository] = []
  ) -> [GlobalSessionCleanupSuggestion] {
    let worktreeItems = items.filter { $0.session.isWorktree }
    let grouped = Dictionary(grouping: worktreeItems) { item in
      cleanupWorktreePath(for: item, repositories: repositories)
    }

    return grouped.compactMap { path, items in
      suggestion(for: path, items: items)
    }
    .sorted { lhs, rhs in
      let nameComparison = lhs.worktreeName.localizedCaseInsensitiveCompare(rhs.worktreeName)
      if nameComparison != .orderedSame {
        return nameComparison == .orderedAscending
      }
      return lhs.worktreePath.localizedCaseInsensitiveCompare(rhs.worktreePath) == .orderedAscending
    }
  }

  private static func suggestion(
    for worktreePath: String,
    items: [GlobalSessionControlPanelItem]
  ) -> GlobalSessionCleanupSuggestion? {
    guard !items.isEmpty else { return nil }
    guard !items.contains(where: \.isPending) else { return nil }
    guard !items.contains(where: { $0.session.isActive }) else { return nil }
    guard !items.contains(where: hasUnsafeStatus) else { return nil }
    guard !items.contains(where: hasBlockingGitHubState) else { return nil }

    let mergedPullRequestNumbers: [Int] = sortedUnique(
      items.compactMap { item in
        guard item.gitHubState?.pullRequestState == .merged else { return nil }
        return item.gitHubState?.pullRequestNumber ?? item.linkedPullRequests.last?.number
      }
    )
    guard !mergedPullRequestNumbers.isEmpty else { return nil }

    return GlobalSessionCleanupSuggestion(
      worktreePath: worktreePath,
      worktreeName: URL(fileURLWithPath: worktreePath).lastPathComponent,
      sessionIDs: sortedUnique(items.filter { !$0.isPending }.map(\.session.id)),
      providerKinds: sortedUnique(items.map(\.providerKind)),
      mergedPullRequestNumbers: mergedPullRequestNumbers
    )
  }

  private static func cleanupWorktreePath(
    for item: GlobalSessionControlPanelItem,
    repositories: [SelectedRepository]
  ) -> String {
    if let match = WorktreeModuleResolver.bestMatch(
      for: item.session.projectPath,
      repositories: repositories
    ), match.worktree.isWorktree {
      return WorktreeModuleResolver.normalizedDirectoryPath(match.worktree.path)
    }

    return WorktreeModuleResolver.normalizedDirectoryPath(item.session.projectPath)
  }

  private static func hasUnsafeStatus(_ item: GlobalSessionControlPanelItem) -> Bool {
    guard let status = item.status else { return false }
    switch status {
    case .thinking, .executingTool, .awaitingApproval:
      return true
    case .waitingForUser, .idle:
      return false
    }
  }

  private static func hasBlockingGitHubState(_ item: GlobalSessionControlPanelItem) -> Bool {
    guard let state = item.gitHubState else { return false }
    if !state.blockers.isEmpty || state.ciStatus == .pending {
      return true
    }
    guard state.hasPullRequest else { return false }
    guard let pullRequestState = state.pullRequestState else { return true }
    switch pullRequestState {
    case .merged:
      return false
    case .open, .closed, .unknown:
      return true
    }
  }

  private static func sortedUnique<T: Hashable & Comparable>(_ values: [T]) -> [T] {
    Array(Set(values)).sorted()
  }

  private static func sortedUnique(_ values: [SessionProviderKind]) -> [SessionProviderKind] {
    values.reduce(into: []) { result, value in
      guard !result.contains(value) else { return }
      result.append(value)
    }
    .sorted { $0.rawValue < $1.rawValue }
  }
}
