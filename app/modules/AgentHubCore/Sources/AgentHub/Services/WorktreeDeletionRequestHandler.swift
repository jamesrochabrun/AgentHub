import AgentHubCLIKit
import Foundation

@MainActor
public protocol WorktreeDeletionRequestHandlingProtocol: AnyObject {
  func handle(_ request: WorktreeDeletionRequest) async throws
}

enum WorktreeDeletionRequestHandlingError: LocalizedError {
  case deletionFailed(String)

  var errorDescription: String? {
    switch self {
    case .deletionFailed(let message):
      return message
    }
  }
}

@MainActor
public final class WorktreeDeletionRequestHandler: WorktreeDeletionRequestHandlingProtocol {
  private let claudeViewModel: CLISessionsViewModel
  private let codexViewModel: CLISessionsViewModel

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
  }

  public func handle(_ request: WorktreeDeletionRequest) async throws {
    let worktreePath = WorktreeModuleResolver.normalizedDirectoryPath(request.worktreePath)
    let worktree = matchingWorktree(at: worktreePath)
      ?? WorktreeBranch(
        name: request.branchName ?? URL(fileURLWithPath: worktreePath).lastPathComponent,
        path: worktreePath,
        isWorktree: true
      )

    if request.removeFromDisk {
      let viewModel = deletionViewModel(for: worktreePath, sourceProvider: request.sourceProvider)
      let succeeded = await viewModel.deleteWorktree(worktree, force: request.force)
      guard succeeded else {
        let message = viewModel.worktreeDeletionError?.message
          ?? "The worktree at \(worktreePath) could not be deleted."
        throw WorktreeDeletionRequestHandlingError.deletionFailed(message)
      }
    }

    removeFromSidebars(worktreePath: worktreePath)
  }

  private func matchingWorktree(at path: String) -> WorktreeBranch? {
    for viewModel in [claudeViewModel, codexViewModel] {
      for repository in viewModel.selectedRepositories {
        if let worktree = repository.worktrees.first(where: {
          WorktreeModuleResolver.normalizedDirectoryPath($0.path) == path
        }) {
          return worktree
        }
      }
    }
    return nil
  }

  private func deletionViewModel(
    for worktreePath: String,
    sourceProvider: WorktreeLaunchProvider?
  ) -> CLISessionsViewModel {
    if containsWorktree(at: worktreePath, in: claudeViewModel) {
      return claudeViewModel
    }
    if containsWorktree(at: worktreePath, in: codexViewModel) {
      return codexViewModel
    }

    switch sourceProvider {
    case .codex:
      return codexViewModel
    case .claude, .none:
      return claudeViewModel
    }
  }

  private func containsWorktree(at path: String, in viewModel: CLISessionsViewModel) -> Bool {
    viewModel.selectedRepositories.contains { repository in
      repository.worktrees.contains {
        WorktreeModuleResolver.normalizedDirectoryPath($0.path) == path
      }
    }
  }

  private func removeFromSidebars(worktreePath: String) {
    for viewModel in [claudeViewModel, codexViewModel] {
      viewModel.archiveMonitoredSessions(inWorktreePath: worktreePath)
      viewModel.forgetOwnedWorktreePath(worktreePath)
      viewModel.refresh()
    }
  }
}
