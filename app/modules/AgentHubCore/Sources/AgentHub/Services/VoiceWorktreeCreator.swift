import AgentHubCLIKit
import Foundation

/// Creates an AgentHub-managed git worktree for a voice-initiated task.
public protocol VoiceWorktreeCreating: Sendable {
  func createWorktree(
    repositoryPath: String,
    branch: String
  ) async throws -> VoiceCreatedWorktree
}

/// In-process twin of the MCP server's worktree creation path: resolves the
/// main repository root, avoids branch/directory collisions, and creates a
/// repo-root worktree (full checkout, per the worktree contract).
public struct VoiceWorktreeCreator: VoiceWorktreeCreating {
  private let service: WorktreeManagementService

  public init(service: WorktreeManagementService = WorktreeManagementService()) {
    self.service = service
  }

  public func createWorktree(
    repositoryPath: String,
    branch: String
  ) async throws -> VoiceCreatedWorktree {
    let mainRepositoryPath = try await service.findMainRepositoryRoot(
      at: repositoryPath
    )
    let requested = WorktreeNaming.sanitizeBranchName(branch)
    let resolvedBranch = await availableBranchName(
      requested,
      at: mainRepositoryPath
    )
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: mainRepositoryPath,
      startPath: nil,
      newBranchName: resolvedBranch,
      directoryName: WorktreeNaming.worktreeDirectoryName(for: resolvedBranch),
      sparseProfile: nil,
      fullCheckout: false
    )
    return VoiceCreatedWorktree(
      repositoryPath: mainRepositoryPath,
      branchName: resolvedBranch,
      worktreePath: creation.worktreePath,
      launchPath: creation.launchPath == creation.worktreePath
        ? nil
        : creation.launchPath
    )
  }

  private func availableBranchName(
    _ requested: String,
    at repositoryPath: String
  ) async -> String {
    var takenBranches: Set<String> = []
    var takenDirectoryNames: Set<String> = []
    if let branches = try? await service.getLocalBranches(at: repositoryPath) {
      takenBranches.formUnion(branches.map(\.name))
    }
    if let worktrees = try? await service.listWorktrees(at: repositoryPath) {
      takenBranches.formUnion(worktrees.compactMap(\.branch))
      takenDirectoryNames.formUnion(
        worktrees.map { URL(fileURLWithPath: $0.path).lastPathComponent }
      )
    }
    return WorktreeNaming.availableBranchName(
      for: requested,
      takenBranches: takenBranches,
      takenDirectoryNames: takenDirectoryNames
    )
  }
}
