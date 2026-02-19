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
