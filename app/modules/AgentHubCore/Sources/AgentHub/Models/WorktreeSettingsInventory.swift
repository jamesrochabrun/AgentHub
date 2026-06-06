import Foundation

struct WorktreeSettingsSnapshot: Equatable {
  let modules: [WorktreeSettingsModule]

  var worktreeCount: Int {
    modules.reduce(0) { $0 + $1.worktrees.count }
  }
}

struct WorktreeSettingsModule: Identifiable, Equatable {
  var id: String { path }

  let name: String
  let path: String
  let worktrees: [WorktreeSettingsWorktree]
}

struct WorktreeSettingsWorktree: Identifiable, Equatable {
  var id: String { path }

  let branchName: String
  let path: String
  let worktree: WorktreeBranch
  let parentModulePath: String
  let providerKinds: [SessionProviderKind]
  let isFocusedInAgentHub: Bool
  let monitoredSessionCount: Int
  let activeMonitoredSessionCount: Int
  let historicalSessionCount: Int

  var providerLabel: String {
    providerKinds.map(\.rawValue).joined(separator: " + ")
  }
}

enum WorktreeSettingsInventoryBuilder {
  static func snapshot(
    claudeRepositories: [SelectedRepository],
    codexRepositories: [SelectedRepository],
    claudeMonitoredSessions: [CLISession],
    codexMonitoredSessions: [CLISession],
    discoveredWorktreesByRepositoryPath: [String: [GitWorktreeInventoryItem]] = [:]
  ) -> WorktreeSettingsSnapshot {
    let mergedRepositories = WorktreeModuleResolver
      .mergedRepositories(claudeRepositories + codexRepositories)
      .reversed()

    let modules = mergedRepositories.map { repository in
      let modulePath = normalized(repository.path)
      let worktrees = worktreeItems(
        for: repository,
        modulePath: modulePath,
        claudeRepositories: claudeRepositories,
        codexRepositories: codexRepositories,
        claudeMonitoredSessions: claudeMonitoredSessions,
        codexMonitoredSessions: codexMonitoredSessions,
        discoveredWorktrees: discoveredWorktreesByRepositoryPath[modulePath] ?? []
      )

      return WorktreeSettingsModule(
        name: repository.name,
        path: modulePath,
        worktrees: worktrees
      )
    }

    return WorktreeSettingsSnapshot(modules: modules)
  }

  private static func worktreeItems(
    for repository: SelectedRepository,
    modulePath: String,
    claudeRepositories: [SelectedRepository],
    codexRepositories: [SelectedRepository],
    claudeMonitoredSessions: [CLISession],
    codexMonitoredSessions: [CLISession],
    discoveredWorktrees: [GitWorktreeInventoryItem]
  ) -> [WorktreeSettingsWorktree] {
    let providerRepositories = [
      (kind: SessionProviderKind.claude, repositories: claudeRepositories),
      (kind: SessionProviderKind.codex, repositories: codexRepositories),
    ]

    var orderedPaths: [String] = []
    var seenPaths: Set<String> = []
    for worktree in repository.worktrees where worktree.isWorktree {
      appendPath(worktree.path, to: &orderedPaths, seen: &seenPaths)
    }
    for provider in providerRepositories {
      guard let providerRepository = provider.repositories.first(where: { normalized($0.path) == modulePath }) else {
        continue
      }
      for worktree in providerRepository.worktrees where worktree.isWorktree {
        appendPath(worktree.path, to: &orderedPaths, seen: &seenPaths)
      }
    }
    for worktree in discoveredWorktrees where worktree.isWorktree {
      let worktreePath = normalized(worktree.path)
      guard worktreePath != modulePath else { continue }
      appendPath(worktreePath, to: &orderedPaths, seen: &seenPaths)
    }

    return orderedPaths.compactMap { worktreePath in
      let providerMatches = providerRepositories.compactMap { provider -> (SessionProviderKind, WorktreeBranch)? in
        guard let repository = provider.repositories.first(where: { normalized($0.path) == modulePath }),
              let worktree = repository.worktrees.first(where: { normalized($0.path) == worktreePath && $0.isWorktree }) else {
          return nil
        }
        return (provider.kind, normalizedWorktree(worktree))
      }

      let providerKinds = providerMatches.map(\.0)
      let discoveredWorktree = discoveredWorktrees.first { normalized($0.path) == worktreePath && $0.isWorktree }
      let representative = providerMatches.first?.1 ?? worktreeBranch(
        from: discoveredWorktree,
        fallbackPath: worktreePath
      )
      let monitoredSessions = providerMatches.flatMap { providerKind, providerWorktree in
        switch providerKind {
        case .claude:
          return sessions(
            in: worktreePath,
            from: claudeMonitoredSessions,
            attachedTo: providerWorktree
          )
        case .codex:
          return sessions(
            in: worktreePath,
            from: codexMonitoredSessions,
            attachedTo: providerWorktree
          )
        }
      }
      let historicalSessionCount = Set(providerMatches.flatMap { $0.1.sessions.map(\.id) }).count
      let monitoredSessionsById = Dictionary(
        monitoredSessions.map { ($0.id, $0) },
        uniquingKeysWith: { existing, new in existing.isActive ? existing : new }
      )

      return WorktreeSettingsWorktree(
        branchName: representative.name,
        path: worktreePath,
        worktree: representative,
        parentModulePath: modulePath,
        providerKinds: providerKinds,
        isFocusedInAgentHub: !providerMatches.isEmpty,
        monitoredSessionCount: monitoredSessionsById.count,
        activeMonitoredSessionCount: monitoredSessionsById.values.filter(\.isActive).count,
        historicalSessionCount: historicalSessionCount
      )
    }
  }

  private static func sessions(
    in worktreePath: String,
    from sessions: [CLISession],
    attachedTo worktree: WorktreeBranch?
  ) -> [CLISession] {
    let pathMatchedSessions = sessions.filter { session in
      let projectPath = normalized(session.projectPath)
      return projectPath == worktreePath || projectPath.hasPrefix(worktreePath + "/")
    }
    guard let worktree else { return [] }

    let attachedSessionIds = Set(worktree.sessions.map(\.id))
    guard !attachedSessionIds.isEmpty else { return [] }
    return pathMatchedSessions.filter { attachedSessionIds.contains($0.id) }
  }

  private static func appendPath(_ path: String, to paths: inout [String], seen: inout Set<String>) {
    let normalizedPath = normalized(path)
    guard seen.insert(normalizedPath).inserted else { return }
    paths.append(normalizedPath)
  }

  private static func normalizedWorktree(_ worktree: WorktreeBranch) -> WorktreeBranch {
    WorktreeBranch(
      name: worktree.name,
      path: normalized(worktree.path),
      isWorktree: worktree.isWorktree,
      sessions: worktree.sessions,
      isExpanded: worktree.isExpanded
    )
  }

  private static func worktreeBranch(
    from discoveredWorktree: GitWorktreeInventoryItem?,
    fallbackPath: String
  ) -> WorktreeBranch {
    let path = normalized(discoveredWorktree?.path ?? fallbackPath)
    let fallbackName = URL(fileURLWithPath: path).lastPathComponent
    let branchName = discoveredWorktree?.branchName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName

    return WorktreeBranch(
      name: branchName,
      path: path,
      isWorktree: true
    )
  }

  private static func normalized(_ path: String) -> String {
    WorktreeModuleResolver.normalizedDirectoryPath(path)
  }
}
