import Foundation
import Testing

@testable import AgentHubCore

@Suite("Worktree inventory view model")
@MainActor
struct WorktreeInventoryViewModelTests {
  @Test("Loads external git worktrees for tracked repositories")
  func loadsExternalWorktreesForTrackedRepositories() async throws {
    let inventory = StubWorktreeInventoryService(results: [
      "/tmp/AgentHub": .success([
        inventoryItem(path: "/tmp/AgentHub", branchName: "main", isWorktree: false),
        inventoryItem(path: "/tmp/AgentHub-external", branchName: "feature/external"),
      ])
    ])
    let viewModel = WorktreeInventoryViewModel(
      inventoryService: inventory,
      removalService: RecordingInventoryRemovalService()
    )

    await viewModel.reload(
      claudeRepositories: [SelectedRepository(path: "/tmp/AgentHub")],
      codexRepositories: [],
      claudeMonitoredSessions: [],
      codexMonitoredSessions: []
    )

    let module = try #require(viewModel.snapshot.modules.first)
    let worktree = try #require(module.worktrees.first)

    #expect(viewModel.loadFailuresByRepositoryPath.isEmpty)
    #expect(module.worktrees.count == 1)
    #expect(worktree.path == "/tmp/AgentHub-external")
    #expect(worktree.branchName == "feature/external")
    #expect(!worktree.isFocusedInAgentHub)
  }

  @Test("Keeps focused rows when git inventory loading fails")
  func keepsFocusedRowsWhenInventoryLoadingFails() async throws {
    let focusedSession = session("focused-session", path: "/tmp/AgentHub-focused")
    let repository = SelectedRepository(
      path: "/tmp/AgentHub",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/AgentHub", isWorktree: false),
        WorktreeBranch(
          name: "feature/focused",
          path: "/tmp/AgentHub-focused",
          isWorktree: true,
          sessions: [focusedSession]
        ),
      ]
    )
    let inventory = StubWorktreeInventoryService(results: [
      "/tmp/AgentHub": .failure(.failed)
    ])
    let viewModel = WorktreeInventoryViewModel(
      inventoryService: inventory,
      removalService: RecordingInventoryRemovalService()
    )

    await viewModel.reload(
      claudeRepositories: [repository],
      codexRepositories: [],
      claudeMonitoredSessions: [focusedSession],
      codexMonitoredSessions: []
    )

    let module = try #require(viewModel.snapshot.modules.first)
    let worktree = try #require(module.worktrees.first)

    #expect(viewModel.loadFailuresByRepositoryPath["/tmp/AgentHub"] != nil)
    #expect(module.worktrees.count == 1)
    #expect(worktree.path == "/tmp/AgentHub-focused")
    #expect(worktree.isFocusedInAgentHub)
    #expect(worktree.monitoredSessionCount == 1)
  }

  @Test("Deletes external worktrees relative to their parent repository")
  func deletesExternalWorktreesRelativeToParentRepository() async throws {
    let remover = RecordingInventoryRemovalService()
    let viewModel = WorktreeInventoryViewModel(
      inventoryService: StubWorktreeInventoryService(results: [
        "/tmp/AgentHub": .success([
          inventoryItem(path: "/tmp/AgentHub-external", branchName: "feature/external"),
        ])
      ]),
      removalService: remover
    )

    await viewModel.reload(
      claudeRepositories: [SelectedRepository(path: "/tmp/AgentHub")],
      codexRepositories: [],
      claudeMonitoredSessions: [],
      codexMonitoredSessions: []
    )
    let worktree = try #require(viewModel.snapshot.modules.first?.worktrees.first)

    let succeeded = await viewModel.delete(worktree)

    #expect(succeeded)
    #expect(viewModel.deletionError == nil)
    #expect(viewModel.deletingWorktreePath == nil)
    #expect(viewModel.snapshot.modules.first?.worktrees.isEmpty == true)
    #expect(await remover.relativeRemovals() == [
      RelativeRemoval(path: "/tmp/AgentHub-external", parentRepoPath: "/tmp/AgentHub", force: false)
    ])
  }

  @Test("Delete failure keeps row and records forceable error")
  func deleteFailureKeepsRowAndRecordsError() async throws {
    let remover = RecordingInventoryRemovalService(removeShouldFail: true)
    let viewModel = WorktreeInventoryViewModel(
      inventoryService: StubWorktreeInventoryService(results: [
        "/tmp/AgentHub": .success([
          inventoryItem(path: "/tmp/AgentHub-external", branchName: "feature/external"),
        ])
      ]),
      removalService: remover
    )

    await viewModel.reload(
      claudeRepositories: [SelectedRepository(path: "/tmp/AgentHub")],
      codexRepositories: [],
      claudeMonitoredSessions: [],
      codexMonitoredSessions: []
    )
    let worktree = try #require(viewModel.snapshot.modules.first?.worktrees.first)

    let succeeded = await viewModel.delete(worktree)

    #expect(!succeeded)
    #expect(viewModel.deletionError?.worktree.path == "/tmp/AgentHub-external")
    #expect(viewModel.snapshot.modules.first?.worktrees.count == 1)
  }
}

private struct StubWorktreeInventoryService: GitWorktreeInventoryServiceProtocol {
  let results: [String: Result<[GitWorktreeInventoryItem], InventoryLoadError>]

  func listWorktrees(at repoPath: String) async throws -> [GitWorktreeInventoryItem] {
    switch results[WorktreeModuleResolver.normalizedDirectoryPath(repoPath)] ?? .success([]) {
    case .success(let worktrees):
      return worktrees
    case .failure(let error):
      throw error
    }
  }
}

private func session(_ id: String, path: String, isActive: Bool = false) -> CLISession {
  CLISession(
    id: id,
    projectPath: path,
    branchName: "feature",
    isWorktree: true,
    isActive: isActive,
    sessionFilePath: "/tmp/\(id).jsonl"
  )
}

private actor RecordingInventoryRemovalService: GitWorktreeRemovalServiceProtocol {
  private let removeShouldFail: Bool
  private let orphanResult: OrphanResult?
  private var removals: [RelativeRemoval] = []

  init(removeShouldFail: Bool = false, orphanResult: OrphanResult? = nil) {
    self.removeShouldFail = removeShouldFail
    self.orphanResult = orphanResult
  }

  func removeWorktree(at worktreePath: String, force: Bool) async throws {
    if removeShouldFail { throw InventoryDeletionError.failed }
    removals.append(RelativeRemoval(path: worktreePath, parentRepoPath: "", force: force))
  }

  func removeWorktree(at worktreePath: String, relativeTo parentRepoPath: String, force: Bool) async throws {
    if removeShouldFail { throw InventoryDeletionError.failed }
    removals.append(RelativeRemoval(path: worktreePath, parentRepoPath: parentRepoPath, force: force))
  }

  nonisolated func checkIfOrphaned(at worktreePath: String) -> (isOrphaned: Bool, parentRepoPath: String?)? {
    guard let orphanResult else { return nil }
    return (orphanResult.isOrphaned, orphanResult.parentRepoPath)
  }

  func removeOrphanedWorktree(at worktreePath: String, parentRepoPath: String) async throws {
    if removeShouldFail { throw InventoryDeletionError.failed }
    removals.append(RelativeRemoval(path: worktreePath, parentRepoPath: parentRepoPath, force: true))
  }

  func relativeRemovals() -> [RelativeRemoval] {
    removals
  }
}

private struct RelativeRemoval: Equatable, Sendable {
  let path: String
  let parentRepoPath: String
  let force: Bool
}

private struct OrphanResult: Sendable {
  let isOrphaned: Bool
  let parentRepoPath: String?
}

private enum InventoryLoadError: Error, Sendable {
  case failed
}

private enum InventoryDeletionError: Error, Sendable {
  case failed
}

private func inventoryItem(
  path: String,
  branchName: String?,
  isWorktree: Bool = true,
  mainRepoPath: String = "/tmp/AgentHub"
) -> GitWorktreeInventoryItem {
  GitWorktreeInventoryItem(
    path: path,
    branchName: branchName,
    isWorktree: isWorktree,
    mainRepoPath: isWorktree ? mainRepoPath : nil
  )
}
