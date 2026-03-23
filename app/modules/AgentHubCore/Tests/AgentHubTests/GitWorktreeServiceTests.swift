import Foundation
import Testing

@testable import AgentHubCore

// MARK: - Test Fixture

struct GitRepoFixture {
  let repoPath: String
  let parentDir: String

  static func create() throws -> GitRepoFixture {
    // Resolve symlinks so paths match git's resolved paths (e.g. /var -> /private/var on macOS)
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(NSTemporaryDirectory(), &resolved) != nil else {
      throw GitFixtureError.commandFailed(command: "realpath", output: "", error: "Failed to resolve temp directory")
    }
    let tempBase = String(cString: resolved)
    let parentDir = tempBase + "/AgentHubTests-\(UUID().uuidString)"
    let repoPath = parentDir + "/repo"
    try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)

    let fixture = GitRepoFixture(repoPath: repoPath, parentDir: parentDir)
    try fixture.runGit("init", "-b", "main")
    try fixture.runGit("config", "user.email", "test@test.com")
    try fixture.runGit("config", "user.name", "Test")
    try "initial".write(toFile: repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "initial")

    return fixture
  }

  @discardableResult
  func runGit(_ args: String..., at path: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: path ?? repoPath)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if process.terminationStatus != 0 {
      throw GitFixtureError.commandFailed(
        command: args.joined(separator: " "),
        output: output,
        error: errorOutput
      )
    }

    return output
  }

  /// Creates a worktree branch and adds it as a sibling directory.
  /// Returns the absolute path to the new worktree.
  func addWorktree(branch: String) throws -> String {
    try runGit("branch", branch)
    let worktreePath = parentDir + "/\(branch)"
    try runGit("worktree", "add", worktreePath, branch)
    return worktreePath
  }

  func worktreeList() throws -> String {
    try runGit("worktree", "list")
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: parentDir)
  }
}

enum GitFixtureError: Error {
  case commandFailed(command: String, output: String, error: String)
}

// MARK: - removeWorktree(at:relativeTo:) Tests

@Suite("GitWorktreeService.removeWorktree(at:relativeTo:)")
struct RemoveWorktreeRelativeToTests {

  @Test("Prunes stale reference when worktree directory is missing")
  func prunesWhenDirectoryMissing() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "test-branch")

    // Verify worktree was created
    let listBefore = try fixture.worktreeList()
    #expect(listBefore.contains("test-branch"))

    // Simulate the bug scenario: directory deleted out from under git
    try FileManager.default.removeItem(atPath: worktreePath)
    #expect(!FileManager.default.fileExists(atPath: worktreePath))

    // This is the fix: removeWorktree(at:relativeTo:) should prune instead of crashing
    let service = GitWorktreeService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath)

    // Verify the prunable worktree entry is gone
    let listAfter = try fixture.worktreeList()
    #expect(!listAfter.contains("test-branch"))
  }

  @Test("Removes worktree when directory still exists")
  func removesWhenDirectoryExists() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "test-branch")

    // Directory should exist
    #expect(FileManager.default.fileExists(atPath: worktreePath))

    let service = GitWorktreeService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath)

    // Directory should be removed
    #expect(!FileManager.default.fileExists(atPath: worktreePath))

    // Worktree list should be clean
    let listAfter = try fixture.worktreeList()
    #expect(!listAfter.contains("test-branch"))
  }
}

// MARK: - checkIfOrphaned Tests

@Suite("GitWorktreeService.checkIfOrphaned")
struct CheckIfOrphanedTests {

  @Test("Returns nil when path does not exist")
  func returnsNilWhenDirectoryMissing() {
    let service = GitWorktreeService()
    let result = service.checkIfOrphaned(at: "/nonexistent/path/\(UUID().uuidString)")
    #expect(result == nil)
  }

  @Test("Detects orphaned worktree when metadata is deleted")
  func detectsOrphanedWorktree() throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "orphan-branch")

    // Delete the worktree metadata from the parent repo's .git/worktrees/
    let metadataPath = fixture.repoPath + "/.git/worktrees/orphan-branch"
    #expect(FileManager.default.fileExists(atPath: metadataPath))
    try FileManager.default.removeItem(atPath: metadataPath)

    // The worktree directory still exists with its .git file,
    // but the parent no longer has metadata for it — it's orphaned
    let service = GitWorktreeService()
    let result = service.checkIfOrphaned(at: worktreePath)

    #expect(result != nil)
    #expect(result?.isOrphaned == true)
    #expect(result?.parentRepoPath == fixture.repoPath)
  }

  @Test("Returns not orphaned for a valid worktree")
  func returnsNotOrphanedForValidWorktree() throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "valid-branch")

    let service = GitWorktreeService()
    let result = service.checkIfOrphaned(at: worktreePath)

    #expect(result != nil)
    #expect(result?.isOrphaned == false)
    #expect(result?.parentRepoPath == fixture.repoPath)
  }
}

// MARK: - Static Helper Tests

@Suite("GitWorktreeService.sanitizeBranchName")
struct SanitizeBranchNameTests {

  @Test("Strips origin/ remote prefix")
  func stripsOriginPrefix() {
    let result = GitWorktreeService.sanitizeBranchName("origin/my-branch")
    #expect(result == "my-branch")
  }

  @Test("Strips upstream/ remote prefix")
  func stripsUpstreamPrefix() {
    let result = GitWorktreeService.sanitizeBranchName("upstream/my-branch")
    #expect(result == "my-branch")
  }

  @Test("Strips remote/ prefix")
  func stripsRemotePrefix() {
    let result = GitWorktreeService.sanitizeBranchName("remote/my-branch")
    #expect(result == "my-branch")
  }

  @Test("Preserves feature/ prefix")
  func preservesFeaturePrefix() {
    let result = GitWorktreeService.sanitizeBranchName("feature/new-thing")
    #expect(result == "feature-new-thing")
  }

  @Test("Preserves bugfix/ prefix")
  func preservesBugfixPrefix() {
    let result = GitWorktreeService.sanitizeBranchName("bugfix/fix-crash")
    #expect(result == "bugfix-fix-crash")
  }

  @Test("Preserves hotfix/ prefix")
  func preservesHotfixPrefix() {
    let result = GitWorktreeService.sanitizeBranchName("hotfix/urgent")
    #expect(result == "hotfix-urgent")
  }

  @Test("Replaces slashes with dashes")
  func replacesSlashes() {
    let result = GitWorktreeService.sanitizeBranchName("feature/sub/path")
    #expect(result == "feature-sub-path")
  }

  @Test("Replaces spaces with dashes")
  func replacesSpaces() {
    let result = GitWorktreeService.sanitizeBranchName("my branch name")
    #expect(result == "my-branch-name")
  }

  @Test("Replaces colons with dashes")
  func replacesColons() {
    let result = GitWorktreeService.sanitizeBranchName("refs:heads:main")
    #expect(result == "refs-heads-main")
  }

  @Test("Replaces backslashes with dashes")
  func replacesBackslashes() {
    let result = GitWorktreeService.sanitizeBranchName("path\\to\\branch")
    #expect(result == "path-to-branch")
  }

  @Test("Returns simple branch names unchanged")
  func simpleNameUnchanged() {
    let result = GitWorktreeService.sanitizeBranchName("my-branch")
    #expect(result == "my-branch")
  }
}

@Suite("GitWorktreeService.worktreeDirectoryName")
struct WorktreeDirectoryNameTests {

  @Test("Prefixes sanitized branch name with repo name")
  func prefixesRepoName() {
    let result = GitWorktreeService.worktreeDirectoryName(for: "my-branch", repoName: "MyApp")
    #expect(result == "MyApp-my-branch")
  }

  @Test("Sanitizes branch name before prefixing")
  func sanitizesBeforePrefixing() {
    let result = GitWorktreeService.worktreeDirectoryName(for: "origin/feature/thing", repoName: "Repo")
    #expect(result == "Repo-feature-thing")
  }

  @Test("Handles feature/ branch with repo prefix")
  func featureBranchWithRepoPrefix() {
    let result = GitWorktreeService.worktreeDirectoryName(for: "feature/login", repoName: "App")
    #expect(result == "App-feature-login")
  }
}

// MARK: - worktreeBranchName Tests

@Suite("GitWorktreeService.worktreeBranchName")
struct WorktreeBranchNameTests {

  @Test("Returns branch name for a valid worktree")
  func returnsBranchName() throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "feature-branch")

    let service = GitWorktreeService()
    let branchName = service.worktreeBranchName(at: worktreePath)

    #expect(branchName == "feature-branch")
  }

  @Test("Returns nil for a nonexistent path")
  func returnsNilForMissingPath() {
    let service = GitWorktreeService()
    let branchName = service.worktreeBranchName(at: "/nonexistent/path/\(UUID().uuidString)")
    #expect(branchName == nil)
  }

  @Test("Returns nil for a regular repo (not a worktree)")
  func returnsNilForMainRepo() throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let service = GitWorktreeService()
    let branchName = service.worktreeBranchName(at: fixture.repoPath)

    // Main repo has a .git directory, not a .git file — should return nil
    #expect(branchName == nil)
  }
}

// MARK: - Locked Worktree Removal Tests

@Suite("GitWorktreeService locked worktree removal")
struct LockedWorktreeRemovalTests {

  @Test("Removes a locked worktree by unlocking first")
  func removesLockedWorktree() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "locked-branch")

    // Lock the worktree
    try fixture.runGit("worktree", "lock", worktreePath)

    // Standard removal should work because our code unlocks first
    let service = GitWorktreeService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath)

    #expect(!FileManager.default.fileExists(atPath: worktreePath))
    let listAfter = try fixture.worktreeList()
    #expect(!listAfter.contains("locked-branch"))
  }

  @Test("Force removes a locked worktree with untracked files")
  func forceRemovesLockedWorktreeWithUntrackedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "locked-dirty")

    // Add untracked file and lock
    try "untracked content".write(
      toFile: worktreePath + "/untracked.txt",
      atomically: true,
      encoding: .utf8
    )
    try fixture.runGit("worktree", "lock", worktreePath)

    let service = GitWorktreeService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath, force: true)

    #expect(!FileManager.default.fileExists(atPath: worktreePath))
    let listAfter = try fixture.worktreeList()
    #expect(!listAfter.contains("locked-dirty"))
  }
}

// MARK: - Branch Deletion Tests

@Suite("GitWorktreeService branch deletion")
struct BranchDeletionTests {

  @Test("Deletes the associated branch when deleteBranch is true")
  func deletesBranchWithWorktree() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "delete-me")

    // Verify branch exists
    let branchesBefore = try fixture.runGit("branch", "--list")
    #expect(branchesBefore.contains("delete-me"))

    let service = GitWorktreeService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath, deleteBranch: true)

    // Worktree should be removed
    #expect(!FileManager.default.fileExists(atPath: worktreePath))

    // Branch should also be deleted
    let branchesAfter = try fixture.runGit("branch", "--list")
    #expect(!branchesAfter.contains("delete-me"))
  }

  @Test("Keeps the branch when deleteBranch is false")
  func keepsBranchWhenNotRequested() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "keep-me")

    let service = GitWorktreeService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath, deleteBranch: false)

    // Worktree should be removed
    #expect(!FileManager.default.fileExists(atPath: worktreePath))

    // Branch should still exist
    let branchesAfter = try fixture.runGit("branch", "--list")
    #expect(branchesAfter.contains("keep-me"))
  }

  @Test("Deletes branch via removeWorktree(at:) when deleteBranch is true")
  func deletesBranchViaDirectRemoval() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "direct-delete")

    let service = GitWorktreeService()
    try await service.removeWorktree(at: worktreePath, deleteBranch: true)

    #expect(!FileManager.default.fileExists(atPath: worktreePath))

    let branchesAfter = try fixture.runGit("branch", "--list")
    #expect(!branchesAfter.contains("direct-delete"))
  }

  @Test("Deletes branch when force-removing a worktree with untracked files")
  func deletesBranchOnForceRemoval() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "force-branch")

    // Add untracked file so non-force removal would fail
    try "dirty".write(
      toFile: worktreePath + "/dirty.txt",
      atomically: true,
      encoding: .utf8
    )

    let service = GitWorktreeService()
    try await service.removeWorktree(
      at: worktreePath,
      relativeTo: fixture.repoPath,
      force: true,
      deleteBranch: true
    )

    #expect(!FileManager.default.fileExists(atPath: worktreePath))

    let branchesAfter = try fixture.runGit("branch", "--list")
    #expect(!branchesAfter.contains("force-branch"))
  }
}

// MARK: - Orphaned Worktree Removal with Branch Deletion Tests

@Suite("GitWorktreeService orphaned worktree removal with branch deletion")
struct OrphanedWorktreeBranchDeletionTests {

  @Test("Deletes branch when removing an orphaned worktree with deleteBranch true")
  func deletesBranchForOrphanedWorktree() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "orphan-delete")

    // Verify branch exists
    let branchesBefore = try fixture.runGit("branch", "--list")
    #expect(branchesBefore.contains("orphan-delete"))

    // Orphan the worktree by deleting its metadata
    let metadataPath = fixture.repoPath + "/.git/worktrees/orphan-delete"
    try FileManager.default.removeItem(atPath: metadataPath)

    let service = GitWorktreeService()
    try await service.removeOrphanedWorktree(
      at: worktreePath,
      parentRepoPath: fixture.repoPath,
      deleteBranch: true
    )

    // Directory should be removed
    #expect(!FileManager.default.fileExists(atPath: worktreePath))

    // Branch should also be deleted
    let branchesAfter = try fixture.runGit("branch", "--list")
    #expect(!branchesAfter.contains("orphan-delete"))
  }

  @Test("Keeps branch when removing an orphaned worktree with deleteBranch false")
  func keepsBranchForOrphanedWorktree() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "orphan-keep")

    // Orphan the worktree
    let metadataPath = fixture.repoPath + "/.git/worktrees/orphan-keep"
    try FileManager.default.removeItem(atPath: metadataPath)

    let service = GitWorktreeService()
    try await service.removeOrphanedWorktree(
      at: worktreePath,
      parentRepoPath: fixture.repoPath,
      deleteBranch: false
    )

    #expect(!FileManager.default.fileExists(atPath: worktreePath))

    // Branch should still exist
    let branchesAfter = try fixture.runGit("branch", "--list")
    #expect(branchesAfter.contains("orphan-keep"))
  }
}

// MARK: - Force Fallback Removal Tests

@Suite("GitWorktreeService force fallback removal")
struct ForceFallbackRemovalTests {

  @Test("Force removal cleans up when worktree has uncommitted changes")
  func forceRemovesWithUncommittedChanges() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "dirty-branch")

    // Stage a modification (uncommitted change)
    try "modified".write(
      toFile: worktreePath + "/README.md",
      atomically: true,
      encoding: .utf8
    )
    try fixture.runGit("add", ".", at: worktreePath)

    let service = GitWorktreeService()
    // Force removal should succeed even with staged changes
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath, force: true)

    #expect(!FileManager.default.fileExists(atPath: worktreePath))
  }

  @Test("Handles already-removed worktree directory gracefully")
  func handlesAlreadyRemovedDirectory() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "already-gone")

    // Remove directory manually
    try FileManager.default.removeItem(atPath: worktreePath)

    let service = GitWorktreeService()
    // Should prune the stale reference without error
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath)

    let listAfter = try fixture.worktreeList()
    #expect(!listAfter.contains("already-gone"))
  }
}
