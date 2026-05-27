import AgentHubCLIKit
import Foundation

public typealias WorktreeCreationError = AgentHubCLIKit.WorktreeManagementError
public typealias WorktreeCreationOperationID = AgentHubCLIKit.WorktreeOperationID
public typealias WorktreeCancellationCleanupResult = AgentHubCLIKit.WorktreeCancellationCleanupResult

public struct LocalBranchesResult: Sendable {
  public let branches: [RemoteBranch]
  public let currentBranchName: String
}

public protocol GitWorktreeRemovalServiceProtocol: Sendable {
  func removeWorktree(at worktreePath: String, force: Bool) async throws
  func removeWorktree(at worktreePath: String, relativeTo parentRepoPath: String, force: Bool) async throws
  func checkIfOrphaned(at worktreePath: String) -> (isOrphaned: Bool, parentRepoPath: String?)?
  func removeOrphanedWorktree(at worktreePath: String, parentRepoPath: String) async throws
}

public actor GitWorktreeService: GitWorktreeRemovalServiceProtocol {
  private let service: WorktreeManagementService

  public init(service: WorktreeManagementService = WorktreeManagementService()) {
    self.service = service
  }

  public func findGitRoot(at path: String) async throws -> String {
    try await service.findGitRoot(at: path)
  }

  public func findMainRepositoryRoot(at path: String) async throws -> String {
    try await service.findMainRepositoryRoot(at: path)
  }

  public func getRemoteBranches(at repoPath: String) async throws -> [RemoteBranch] {
    try await service.getRemoteBranches(at: repoPath).map(Self.remoteBranch)
  }

  public func fetchAndGetRemoteBranches(at repoPath: String) async throws -> [RemoteBranch] {
    try await service.fetchAndGetRemoteBranches(at: repoPath).map(Self.remoteBranch)
  }

  public func getLocalBranches(at repoPath: String) async throws -> [RemoteBranch] {
    try await service.getLocalBranches(at: repoPath).map(Self.remoteBranch)
  }

  public func getLocalBranchesWithCurrent(at repoPath: String) async throws -> LocalBranchesResult {
    let result = try await service.getLocalBranchesWithCurrent(at: repoPath)
    return LocalBranchesResult(
      branches: result.branches.map(Self.remoteBranch),
      currentBranchName: result.currentBranchName
    )
  }

  public func createWorktree(
    at repoPath: String,
    branch: String,
    directoryName: String
  ) async throws -> String {
    try await service.createWorktree(
      at: repoPath,
      branch: branch,
      directoryName: directoryName
    )
  }

  public func createWorktreeWithNewBranch(
    at repoPath: String,
    newBranchName: String,
    directoryName: String,
    startPoint: String? = nil
  ) async throws -> String {
    try await service.createWorktreeWithNewBranch(
      at: repoPath,
      newBranchName: newBranchName,
      directoryName: directoryName,
      startPoint: startPoint
    )
  }

  public func createWorktreeWithNewBranch(
    at repoPath: String,
    newBranchName: String,
    directoryName: String,
    startPoint: String? = nil,
    operationID: WorktreeCreationOperationID,
    onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void
  ) async throws -> String {
    try await service.createWorktreeWithNewBranch(
      at: repoPath,
      newBranchName: newBranchName,
      directoryName: directoryName,
      startPoint: startPoint,
      operationID: operationID,
      onProgress: onProgress
    )
  }

  public func cancelWorktreeCreation(_ operationID: WorktreeCreationOperationID) async {
    await service.cancelWorktreeCreation(operationID)
  }

  public func cleanupCancelledWorktreeCreation(
    repoPath: String,
    newBranchName: String,
    directoryName: String
  ) async -> WorktreeCancellationCleanupResult {
    await service.cleanupCancelledWorktreeCreation(
      repoPath: repoPath,
      newBranchName: newBranchName,
      directoryName: directoryName
    )
  }

  public func captureStash(at repoPath: String) async throws -> String? {
    try await service.captureStash(at: repoPath)
  }

  public func applyStash(_ ref: String, at path: String) async throws {
    try await service.applyStash(ref, at: path)
  }

  public func captureWorkingTreeChanges(at repoPath: String) async throws -> WorktreeChangeSnapshot? {
    try await service.captureWorkingTreeChanges(at: repoPath)
  }

  public func applyWorkingTreeChanges(
    _ snapshot: WorktreeChangeSnapshot,
    from sourcePath: String,
    to targetPath: String
  ) async throws {
    try await service.applyWorkingTreeChanges(snapshot, from: sourcePath, to: targetPath)
  }

  public func getCurrentBranch(at repoPath: String) async throws -> String {
    try await service.getCurrentBranch(at: repoPath)
  }

  public func getCurrentBranchFast(at repoPath: String) async throws -> String {
    try await service.getCurrentBranchFast(at: repoPath)
  }

  public func hasUncommittedChanges(at repoPath: String) async throws -> Bool {
    try await service.hasUncommittedChanges(at: repoPath)
  }

  public func removeWorktree(at worktreePath: String, force: Bool = false) async throws {
    try await service.removeWorktree(at: worktreePath, force: force)
  }

  public func removeWorktree(
    at worktreePath: String,
    relativeTo parentRepoPath: String,
    force: Bool = false
  ) async throws {
    try await service.removeWorktree(
      at: worktreePath,
      relativeTo: parentRepoPath,
      force: force
    )
  }

  public nonisolated func checkIfOrphaned(at worktreePath: String) -> (isOrphaned: Bool, parentRepoPath: String?)? {
    WorktreeManagementService().checkIfOrphaned(at: worktreePath)
  }

  public func removeOrphanedWorktree(at worktreePath: String, parentRepoPath: String) async throws {
    try await service.removeOrphanedWorktree(at: worktreePath, parentRepoPath: parentRepoPath)
  }

  public static func sanitizeBranchName(_ branch: String) -> String {
    WorktreeNaming.sanitizeBranchName(branch)
  }

  public static func worktreeDirectoryName(for branch: String, repoName: String) -> String {
    WorktreeNaming.worktreeDirectoryName(for: branch, repoName: repoName)
  }

  private static func remoteBranch(_ branch: BranchInfo) -> RemoteBranch {
    RemoteBranch(name: branch.name, remote: branch.remote)
  }
}
