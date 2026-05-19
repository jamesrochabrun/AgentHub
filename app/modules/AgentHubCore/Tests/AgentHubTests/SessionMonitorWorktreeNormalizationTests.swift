import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session monitor worktree normalization")
struct SessionMonitorWorktreeNormalizationTests {
  @Test("Claude monitor adds a worktree path as its parent repository")
  func claudeAddRepositoryNormalizesWorktreePath() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-normalization")

    let service = CLISessionMonitorService(claudeDataPath: fixture.parentDir + "/claude")
    let added = await service.addRepository(worktreePath)
    let repositories = await service.getSelectedRepositories()

    #expect(added?.path == fixture.repoPath)
    #expect(repositories.map(\.path) == [fixture.repoPath])
    #expect(repositories.first?.worktrees.contains(where: { $0.path == worktreePath }) == true)
  }

  @Test("Claude restore dedupes parent and worktree paths")
  func claudeRestoreDedupesWorktreePath() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-restore")

    let service = CLISessionMonitorService(claudeDataPath: fixture.parentDir + "/claude")
    let repositories = await service.restoreRepositoriesSkeleton([fixture.repoPath, worktreePath])

    #expect(repositories.map(\.path) == [fixture.repoPath])
    #expect(repositories.first?.worktrees.contains(where: { $0.path == worktreePath }) == true)
  }

  @Test("Claude parent add hides external worktrees")
  func claudeParentAddHidesExternalWorktrees() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-external")

    let service = CLISessionMonitorService(claudeDataPath: fixture.parentDir + "/claude")
    let added = await service.addRepository(fixture.repoPath)

    #expect(added?.path == fixture.repoPath)
    #expect(added?.worktrees.contains(where: { $0.path == worktreePath }) == false)
  }

  @Test("Codex monitor adds a worktree path as its parent repository")
  func codexAddRepositoryNormalizesWorktreePath() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-codex-normalization")

    let service = CodexSessionMonitorService(codexDataPath: fixture.parentDir + "/codex")
    let added = await service.addRepository(worktreePath)
    let repositories = await service.getSelectedRepositories()

    #expect(added?.path == fixture.repoPath)
    #expect(repositories.map(\.path) == [fixture.repoPath])
    #expect(repositories.first?.worktrees.contains(where: { $0.path == worktreePath }) == true)
  }

  @Test("Codex restore dedupes parent and worktree paths")
  func codexRestoreDedupesWorktreePath() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-codex-restore")

    let service = CodexSessionMonitorService(codexDataPath: fixture.parentDir + "/codex")
    let repositories = await service.restoreRepositoriesSkeleton([fixture.repoPath, worktreePath])

    #expect(repositories.map(\.path) == [fixture.repoPath])
    #expect(repositories.first?.worktrees.contains(where: { $0.path == worktreePath }) == true)
  }

  @Test("Codex parent add hides external worktrees")
  func codexParentAddHidesExternalWorktrees() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-codex-external")

    let service = CodexSessionMonitorService(codexDataPath: fixture.parentDir + "/codex")
    let added = await service.addRepository(fixture.repoPath)

    #expect(added?.path == fixture.repoPath)
    #expect(added?.worktrees.contains(where: { $0.path == worktreePath }) == false)
  }
}
