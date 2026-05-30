import Foundation

@MainActor
@Observable
final class WorktreeInventoryViewModel {
  private(set) var snapshot = WorktreeSettingsSnapshot(modules: [])
  private(set) var isLoading = false
  private(set) var loadFailuresByRepositoryPath: [String: String] = [:]
  private(set) var deletingWorktreePath: String?
  private(set) var deletionError: WorktreeInventoryDeletionError?

  @ObservationIgnored private let inventoryService: any GitWorktreeInventoryServiceProtocol
  @ObservationIgnored private let removalService: any GitWorktreeRemovalServiceProtocol
  @ObservationIgnored private var locallyDeletedWorktreePaths: Set<String> = []

  init(
    inventoryService: any GitWorktreeInventoryServiceProtocol = GitWorktreeService(),
    removalService: any GitWorktreeRemovalServiceProtocol = GitWorktreeService()
  ) {
    self.inventoryService = inventoryService
    self.removalService = removalService
  }

  func reload(
    claudeRepositories: [SelectedRepository],
    codexRepositories: [SelectedRepository],
    claudeMonitoredSessions: [CLISession],
    codexMonitoredSessions: [CLISession]
  ) async {
    snapshot = makeSnapshot(
      claudeRepositories: claudeRepositories,
      codexRepositories: codexRepositories,
      claudeMonitoredSessions: claudeMonitoredSessions,
      codexMonitoredSessions: codexMonitoredSessions
    )

    let repositoryPaths = Self.repositoryPaths(
      claudeRepositories: claudeRepositories,
      codexRepositories: codexRepositories
    )
    guard !repositoryPaths.isEmpty else {
      isLoading = false
      loadFailuresByRepositoryPath = [:]
      return
    }

    isLoading = true
    let inventoryService = inventoryService
    let loadResult = await withTaskGroup(of: WorktreeInventoryLoadResult.self) { group in
      for path in repositoryPaths {
        group.addTask {
          do {
            let worktrees = try await inventoryService.listWorktrees(at: path)
            return WorktreeInventoryLoadResult(
              repositoryPath: path,
              worktrees: worktrees,
              failureMessage: nil
            )
          } catch {
            return WorktreeInventoryLoadResult(
              repositoryPath: path,
              worktrees: [],
              failureMessage: error.localizedDescription
            )
          }
        }
      }

      var worktreesByRepositoryPath: [String: [GitWorktreeInventoryItem]] = [:]
      var failuresByRepositoryPath: [String: String] = [:]
      for await result in group {
        if let failureMessage = result.failureMessage {
          failuresByRepositoryPath[result.repositoryPath] = failureMessage
        } else {
          worktreesByRepositoryPath[result.repositoryPath] = result.worktrees
        }
      }

      return (worktreesByRepositoryPath, failuresByRepositoryPath)
    }

    snapshot = makeSnapshot(
      claudeRepositories: claudeRepositories,
      codexRepositories: codexRepositories,
      claudeMonitoredSessions: claudeMonitoredSessions,
      codexMonitoredSessions: codexMonitoredSessions,
      discoveredWorktreesByRepositoryPath: loadResult.0
    )
    loadFailuresByRepositoryPath = loadResult.1
    isLoading = false
  }

  @discardableResult
  func delete(_ worktree: WorktreeSettingsWorktree, force: Bool = false) async -> Bool {
    deletingWorktreePath = worktree.path
    deletionError = nil

    do {
      try await removalService.removeWorktree(
        at: worktree.path,
        relativeTo: worktree.parentModulePath,
        force: force
      )
      locallyDeletedWorktreePaths.insert(Self.normalized(worktree.path))
      snapshot = filteredSnapshot(snapshot)
      deletingWorktreePath = nil
      return true
    } catch {
      deletionError = deletionFailure(for: worktree, error: error)
      deletingWorktreePath = nil
      return false
    }
  }

  @discardableResult
  func deleteOrphaned(_ worktree: WorktreeSettingsWorktree, parentRepoPath: String) async -> Bool {
    deletingWorktreePath = worktree.path
    deletionError = nil

    do {
      try await removalService.removeOrphanedWorktree(
        at: worktree.path,
        parentRepoPath: parentRepoPath
      )
      locallyDeletedWorktreePaths.insert(Self.normalized(worktree.path))
      snapshot = filteredSnapshot(snapshot)
      deletingWorktreePath = nil
      return true
    } catch {
      deletionError = WorktreeInventoryDeletionError(
        worktree: worktree,
        message: "Failed to delete orphaned worktree: \(error.localizedDescription)"
      )
      deletingWorktreePath = nil
      return false
    }
  }

  func clearDeletionError() {
    deletionError = nil
  }

  private func deletionFailure(
    for worktree: WorktreeSettingsWorktree,
    error: Error
  ) -> WorktreeInventoryDeletionError {
    if let orphanInfo = removalService.checkIfOrphaned(at: worktree.path),
       orphanInfo.isOrphaned {
      return WorktreeInventoryDeletionError(
        worktree: worktree,
        message: error.localizedDescription,
        isOrphaned: true,
        parentRepoPath: orphanInfo.parentRepoPath
      )
    }

    return WorktreeInventoryDeletionError(
      worktree: worktree,
      message: error.localizedDescription
    )
  }

  private static func repositoryPaths(
    claudeRepositories: [SelectedRepository],
    codexRepositories: [SelectedRepository]
  ) -> [String] {
    WorktreeModuleResolver
      .mergedRepositories(claudeRepositories + codexRepositories)
      .map { WorktreeModuleResolver.normalizedDirectoryPath($0.path) }
  }

  private func makeSnapshot(
    claudeRepositories: [SelectedRepository],
    codexRepositories: [SelectedRepository],
    claudeMonitoredSessions: [CLISession],
    codexMonitoredSessions: [CLISession],
    discoveredWorktreesByRepositoryPath: [String: [GitWorktreeInventoryItem]] = [:]
  ) -> WorktreeSettingsSnapshot {
    filteredSnapshot(
      WorktreeSettingsInventoryBuilder.snapshot(
        claudeRepositories: claudeRepositories,
        codexRepositories: codexRepositories,
        claudeMonitoredSessions: claudeMonitoredSessions,
        codexMonitoredSessions: codexMonitoredSessions,
        discoveredWorktreesByRepositoryPath: discoveredWorktreesByRepositoryPath
      )
    )
  }

  private func filteredSnapshot(_ snapshot: WorktreeSettingsSnapshot) -> WorktreeSettingsSnapshot {
    guard !locallyDeletedWorktreePaths.isEmpty else { return snapshot }

    return WorktreeSettingsSnapshot(
      modules: snapshot.modules.map { module in
        WorktreeSettingsModule(
          name: module.name,
          path: module.path,
          worktrees: module.worktrees.filter {
            !locallyDeletedWorktreePaths.contains(Self.normalized($0.path))
          }
        )
      }
    )
  }

  private static func normalized(_ path: String) -> String {
    WorktreeModuleResolver.normalizedDirectoryPath(path)
  }
}

struct WorktreeInventoryDeletionError: Identifiable {
  let id = UUID()
  let worktree: WorktreeSettingsWorktree
  let message: String
  let isOrphaned: Bool
  let parentRepoPath: String?

  init(
    worktree: WorktreeSettingsWorktree,
    message: String,
    isOrphaned: Bool = false,
    parentRepoPath: String? = nil
  ) {
    self.worktree = worktree
    self.message = message
    self.isOrphaned = isOrphaned
    self.parentRepoPath = parentRepoPath
  }
}

private struct WorktreeInventoryLoadResult: Sendable {
  let repositoryPath: String
  let worktrees: [GitWorktreeInventoryItem]
  let failureMessage: String?
}
