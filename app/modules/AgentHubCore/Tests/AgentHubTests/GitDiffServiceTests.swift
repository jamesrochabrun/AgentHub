import Foundation
import Testing

@testable import AgentHubGitDiff

@Suite("GitDiffService")
struct GitDiffServiceTests {

  @Test("lists and renders unstaged changes")
  func listsAndRendersUnstagedChanges() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(file.additions == 1)
    #expect(file.deletions == 1)
    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "changed")
    #expect(!payload.isLimitedContext)
  }

  @Test("lists and renders staged changes")
  func listsAndRendersStagedChanges() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "staged".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "README.md")

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .staged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .staged, baseBranch: nil)

    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "staged")
    #expect(!payload.isLimitedContext)
  }

  @Test("lists and renders branch changes")
  func listsAndRendersBranchChanges() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try fixture.runGit("checkout", "-b", "feature/diff")
    try "branch".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "README.md")
    try fixture.runGit("commit", "-m", "branch change")

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .branch, baseBranch: "main")
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .branch, baseBranch: "main")

    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "branch")
    #expect(!payload.isLimitedContext)
  }

  @Test("renders deleted unstaged files")
  func rendersDeletedUnstagedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try FileManager.default.removeItem(atPath: fixture.repoPath + "/README.md")

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "")
  }

  @Test("lists and renders untracked files")
  func listsAndRendersUntrackedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "new file".write(toFile: fixture.repoPath + "/NewFile.txt", atomically: true, encoding: .utf8)

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "NewFile.txt" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(payload.oldContent == "")
    #expect(payload.newContent == "new file")
    #expect(!payload.isLimitedContext)
    #expect(file.status == .untracked)
  }

  @Test("uses stable file ids across refreshes")
  func usesStableFileIdsAcrossRefreshes() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)

    let service = GitDiffService()
    let first = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let second = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(first.files.map(\.id) == second.files.map(\.id))
  }

  @Test("detects unstaged renames")
  func detectsUnstagedRenames() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try FileManager.default.moveItem(
      atPath: fixture.repoPath + "/README.md",
      toPath: fixture.repoPath + "/Renamed.md"
    )

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "Renamed.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(file.status == .renamed)
    #expect(file.oldRelativePath == "README.md")
    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "initial")
  }

  @Test("uses hunk fallback for large tracked files")
  func usesHunkFallbackForLargeTrackedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "changed line\nsecond line\n".write(
      toFile: fixture.repoPath + "/README.md",
      atomically: true,
      encoding: .utf8
    )

    let service = GitDiffService(renderPolicy: GitDiffRenderPolicy(maxFullContentBytes: 8))
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(payload.isLimitedContext)
    #expect(payload.renderMode == .limitedHunks)
    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "changed line\nsecond line")
  }

  @Test("uses no-index hunk fallback for large untracked files")
  func usesNoIndexHunkFallbackForLargeUntrackedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "alpha\nbeta\n".write(toFile: fixture.repoPath + "/LargeNew.txt", atomically: true, encoding: .utf8)

    let service = GitDiffService(renderPolicy: GitDiffRenderPolicy(maxFullContentBytes: 4))
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "LargeNew.txt" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(payload.isLimitedContext)
    #expect(payload.renderMode == .limitedHunks)
    #expect(payload.oldContent == "")
    #expect(payload.newContent == "alpha\nbeta")
  }
}
