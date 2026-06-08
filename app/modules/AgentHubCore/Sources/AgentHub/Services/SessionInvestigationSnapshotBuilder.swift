//
//  SessionInvestigationSnapshotBuilder.swift
//  AgentHub
//

import Foundation

@MainActor
public enum SessionInvestigationSnapshotBuilder {
  public static func make(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    generatedAt: Date = Date()
  ) -> SessionInvestigationSnapshot {
    let repositories = mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    )

    let repositorySnapshots = repositories.map { repository in
      SessionInvestigationRepositorySnapshot(
        name: repository.name,
        path: repository.path,
        worktreeCount: repository.worktrees.filter(\.isWorktree).count,
        sessionCount: repository.totalSessionCount
      )
    }

    let worktreeSnapshots = repositories.flatMap { repository in
      repository.worktrees.map { worktree in
        SessionInvestigationWorktreeSnapshot(
          name: worktree.name,
          path: worktree.path,
          repositoryPath: repository.path,
          isWorktree: worktree.isWorktree,
          sessionCount: worktree.sessions.count,
          activeSessionCount: worktree.activeSessionCount,
          latestActivityAt: worktree.lastActivityAt
        )
      }
    }

    let sessionSnapshots = makeSessionSnapshots(
      viewModel: claudeViewModel,
      provider: .claude,
      customNames: claudeViewModel.sessionCustomNames,
      repositories: repositories
    ) + makeSessionSnapshots(
      viewModel: codexViewModel,
      provider: .codex,
      customNames: codexViewModel.sessionCustomNames,
      repositories: repositories
    )

    let pendingSnapshots = claudeViewModel.pendingHubSessions.map {
      makePendingSessionSnapshot($0, provider: .claude)
    } + codexViewModel.pendingHubSessions.map {
      makePendingSessionSnapshot($0, provider: .codex)
    }

    return SessionInvestigationSnapshot(
      generatedAt: generatedAt,
      repositories: repositorySnapshots,
      worktrees: worktreeSnapshots,
      sessions: sessionSnapshots,
      pendingSessions: pendingSnapshots
    )
  }

  private static func makeSessionSnapshots(
    viewModel: CLISessionsViewModel,
    provider: SessionProviderKind,
    customNames: [String: String],
    repositories: [SelectedRepository]
  ) -> [SessionInvestigationSessionSnapshot] {
    let monitoredItems = viewModel.monitoredSessions
    let monitoredStates = Dictionary(uniqueKeysWithValues: monitoredItems.map { ($0.session.id, $0.state) })
    let monitoredIds = Set(monitoredItems.map(\.session.id))

    var sessions = viewModel.allSessions
    for item in monitoredItems where !sessions.contains(where: { $0.id == item.session.id }) {
      sessions.append(item.session)
    }

    var seen = Set<String>()
    return sessions.compactMap { session in
      let identity = "\(provider.rawValue):\(session.id)"
      guard seen.insert(identity).inserted else { return nil }
      let state = monitoredStates[session.id] ?? nil
      let match = WorktreeModuleResolver.bestMatch(for: session.projectPath, repositories: repositories)
      let fileMetadata = sessionFileMetadata(for: viewModel.sessionFileURL(for: session))

      return SessionInvestigationSessionSnapshot(
        id: session.id,
        provider: provider,
        displayName: customNames[session.id] ?? session.displayName,
        projectPath: session.projectPath,
        repositoryPath: match?.repository.path,
        worktreePath: match?.worktree.isWorktree == true ? match?.worktree.path : nil,
        branchName: session.branchName,
        isWorktree: session.isWorktree,
        isActive: session.isActive,
        isMonitored: monitoredIds.contains(session.id),
        status: state?.status.displayName,
        currentTool: state?.currentTool,
        model: state?.model,
        inputTokens: state?.inputTokens ?? 0,
        outputTokens: state?.outputTokens ?? 0,
        contextUsagePercent: state.map { $0.contextWindowUsagePercentage * 100 },
        messageCount: max(session.messageCount, state?.messageCount ?? 0),
        lastActivityAt: state?.lastActivityAt ?? session.lastActivityAt,
        firstMessagePreview: previewText(session.firstMessage),
        lastMessagePreview: previewText(session.lastMessage),
        sessionFilePath: fileMetadata.path,
        sessionFileExists: fileMetadata.exists,
        sessionFileByteCount: fileMetadata.byteCount,
        sessionFileModifiedAt: fileMetadata.modifiedAt,
        localhostURL: state?.detectedLocalhostURL?.absoluteString,
        isAwaitingApproval: state?.isAwaitingApproval ?? false
      )
    }
  }

  private static func makePendingSessionSnapshot(
    _ pending: PendingHubSession,
    provider: SessionProviderKind
  ) -> SessionInvestigationPendingSessionSnapshot {
    SessionInvestigationPendingSessionSnapshot(
      id: pending.id,
      provider: provider,
      worktreeName: pending.worktree.name,
      worktreePath: pending.worktree.path,
      startedAt: pending.startedAt
    )
  }

  private static func mergedRepositories(_ repositories: [SelectedRepository]) -> [SelectedRepository] {
    var order: [String] = []
    var byPath: [String: SelectedRepository] = [:]

    for repository in repositories {
      if var existing = byPath[repository.path] {
        existing.worktrees = mergedWorktrees(existing.worktrees + repository.worktrees)
        existing.isExpanded = existing.isExpanded || repository.isExpanded
        byPath[repository.path] = existing
      } else {
        order.append(repository.path)
        byPath[repository.path] = repository
      }
    }

    return order.compactMap { byPath[$0] }
  }

  private static func mergedWorktrees(_ worktrees: [WorktreeBranch]) -> [WorktreeBranch] {
    var order: [String] = []
    var byPath: [String: WorktreeBranch] = [:]

    for worktree in worktrees {
      if var existing = byPath[worktree.path] {
        existing.sessions = mergedSessions(existing.sessions + worktree.sessions)
        existing.isExpanded = existing.isExpanded || worktree.isExpanded
        byPath[worktree.path] = existing
      } else {
        order.append(worktree.path)
        byPath[worktree.path] = worktree
      }
    }

    return order.compactMap { byPath[$0] }
  }

  private static func mergedSessions(_ sessions: [CLISession]) -> [CLISession] {
    var seen = Set<String>()
    return sessions.filter { session in
      seen.insert(session.id).inserted
    }
  }

  private static func sessionFileMetadata(
    for url: URL?
  ) -> (path: String?, exists: Bool, byteCount: Int?, modifiedAt: Date?) {
    guard let url else {
      return (path: nil, exists: false, byteCount: nil, modifiedAt: nil)
    }

    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return (path: url.path, exists: false, byteCount: nil, modifiedAt: nil)
    }

    return (
      path: url.path,
      exists: true,
      byteCount: (attributes[.size] as? NSNumber)?.intValue,
      modifiedAt: attributes[.modificationDate] as? Date
    )
  }

  private static func previewText(_ text: String?, limit: Int = 240) -> String? {
    guard let text else { return nil }
    let normalized = text
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    if normalized.count <= limit {
      return normalized
    }
    return String(normalized.prefix(limit)) + "..."
  }
}
