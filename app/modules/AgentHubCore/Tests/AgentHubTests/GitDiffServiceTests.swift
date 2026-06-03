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

  @Test("branch changes are scoped to the selected worktree")
  func branchChangesAreScopedToSelectedWorktree() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-worktree-scoped-diff")
    try "parent only".write(toFile: fixture.repoPath + "/ParentOnly.swift", atomically: true, encoding: .utf8)
    try "worktree branch".write(toFile: worktreePath + "/WorktreeOnly.swift", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "WorktreeOnly.swift", at: worktreePath)
    try fixture.runGit("commit", "-m", "worktree branch change", at: worktreePath)

    let service = GitDiffService()
    let state = try await service.changedFiles(at: worktreePath, mode: .branch, baseBranch: "main")

    #expect(state.files.map(\.relativePath) == ["WorktreeOnly.swift"])
    #expect(state.files.allSatisfy { $0.filePath.hasPrefix(worktreePath + "/") })
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

  // MARK: - Large-worktree gate (native git path)

  /// Forcing the gate (threshold 0) must produce the same file set, counts, and statuses
  /// as the default libgit2 path — so monorepos don't regress correctness, only get faster.
  @Test("large-worktree gate: native unstaged matches libgit2 results")
  func largeWorktreeNativeUnstagedMatchesLibgit2() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try "brand new".write(toFile: fixture.repoPath + "/Added.txt", atomically: true, encoding: .utf8)
    let libgit2 = GitDiffService()
    let native = GitDiffService(largeWorktreeIndexByteThreshold: 0)
    let expected = try await libgit2.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let actual = try await native.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    #expect(Set(actual.files.map(\.relativePath)) == Set(expected.files.map(\.relativePath)))
    let readme = try #require(actual.files.first { $0.relativePath == "README.md" })
    #expect(readme.status == .modified)
    #expect(readme.additions == 1)
    #expect(readme.deletions == 1)
    let added = try #require(actual.files.first { $0.relativePath == "Added.txt" })
    #expect(added.status == .untracked)
  }

  @Test("large-worktree gate: native staged reports status and renames")
  func largeWorktreeNativeStagedReportsStatusAndRenames() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try fixture.runGit("mv", "README.md", "Doc.md")               // staged rename
    try "added".write(toFile: fixture.repoPath + "/Added.txt", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "Added.txt")                         // staged add
    let native = GitDiffService(largeWorktreeIndexByteThreshold: 0)
    let state = try await native.changedFiles(at: fixture.repoPath, mode: .staged, baseBranch: nil)
    let renamed = try #require(state.files.first { $0.relativePath == "Doc.md" })
    #expect(renamed.status == .renamed)
    #expect(renamed.oldRelativePath == "README.md")
    let added = try #require(state.files.first { $0.relativePath == "Added.txt" })
    #expect(added.status == .added)
  }

  @Test("large-worktree gate: renders a file listed via the native path")
  func largeWorktreeGateRendersListedFile() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    let native = GitDiffService(largeWorktreeIndexByteThreshold: 0)
    let state = try await native.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first { $0.relativePath == "README.md" })
    let payload = try await native.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "changed")
  }
}

@Suite("LocalDiffSummaryService")
struct LocalDiffSummaryServiceTests {

  @Test("counts unique files across branch staged and unstaged diffs")
  func countsUniqueFilesAcrossDiffModes() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try fixture.runGit("checkout", "-b", "feature/summary")
    try "branch".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "README.md")
    try fixture.runGit("commit", "-m", "branch change")

    try "unstaged".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try "staged".write(toFile: fixture.repoPath + "/StagedOnly.swift", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "StagedOnly.swift")
    try "untracked".write(toFile: fixture.repoPath + "/UntrackedOnly.swift", atomically: true, encoding: .utf8)

    let service = LocalDiffSummaryService(minimumRefreshInterval: 0)
    let summary = await service.summary(for: fixture.repoPath)

    #expect(summary.fileCount == 3)
  }

  @Test("returns empty summary for non git paths")
  func returnsEmptySummaryForNonGitPaths() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "LocalDiffSummaryServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let service = LocalDiffSummaryService(minimumRefreshInterval: 0)
    let summary = await service.summary(for: directory.path)

    #expect(summary == .empty)
  }
}
