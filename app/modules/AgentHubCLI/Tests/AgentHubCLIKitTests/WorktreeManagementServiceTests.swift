import Foundation
import Testing

@testable import AgentHubCLIKit

struct GitRepoFixture {
  let repoPath: String
  let parentDir: String

  static func create() throws -> GitRepoFixture {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(NSTemporaryDirectory(), &resolved) != nil else {
      throw GitFixtureError.commandFailed(command: "realpath", output: "", error: "Failed to resolve temp directory")
    }
    let tempBase = String(cString: resolved)
    let parentDir = tempBase + "/AgentHubCLITests-\(UUID().uuidString)"
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

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if process.terminationStatus != 0 {
      throw GitFixtureError.commandFailed(
        command: args.joined(separator: " "),
        output: output,
        error: errorOutput
      )
    }

    return output
  }

  func addSiblingWorktree(branch: String) throws -> String {
    try runGit("branch", branch)
    let worktreePath = parentDir + "/\(branch)"
    try runGit("worktree", "add", worktreePath, branch)
    return worktreePath
  }

  func installSleepingPostCheckoutHook(seconds: Int) throws {
    let hookPath = repoPath + "/.git/hooks/post-checkout"
    let contents = """
    #!/bin/sh
    sleep \(seconds)
    """
    try contents.write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
  }

  func localBranchExists(_ branch: String) throws -> Bool {
    let output = try runGit("branch", "--list", branch)
    return !output.isEmpty
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: parentDir)
  }
}

enum GitFixtureError: Error {
  case commandFailed(command: String, output: String, error: String)
}

@Suite("WorktreeManagementService .worktrees convention")
struct WorktreeConventionTests {
  @Test("Creates new branch worktrees under repo-local .worktrees")
  func createsWorktreeUnderRepoLocalDirectory() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let service = WorktreeManagementService()
    let path = try await service.createWorktreeWithNewBranch(
      at: fixture.repoPath,
      newBranchName: "feature/example",
      directoryName: WorktreeNaming.worktreeDirectoryName(for: "feature/example")
    )

    #expect(path == fixture.repoPath + "/.worktrees/feature-example")
    #expect(FileManager.default.fileExists(atPath: path))

    let exclude = try String(contentsOfFile: fixture.repoPath + "/.git/info/exclude", encoding: .utf8)
    #expect(exclude.components(separatedBy: .newlines).contains(".worktrees/"))
  }

  @Test("Creates from a linked worktree but stores under the main repository")
  func linkedWorktreeInvocationUsesMainRepositoryStorage() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let existingPath = try fixture.addSiblingWorktree(branch: "existing")
    let service = WorktreeManagementService()

    let path = try await service.createWorktreeWithNewBranch(
      at: existingPath,
      newBranchName: "feature/from-linked",
      directoryName: "feature-from-linked"
    )

    #expect(path == fixture.repoPath + "/.worktrees/feature-from-linked")
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test("Uses start point when creating a new branch")
  func usesStartPoint() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try fixture.runGit("checkout", "-b", "base")
    try "base".write(toFile: fixture.repoPath + "/BASE.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "base")
    try fixture.runGit("checkout", "main")

    let service = WorktreeManagementService()
    let path = try await service.createWorktreeWithNewBranch(
      at: fixture.repoPath,
      newBranchName: "feature/from-base",
      directoryName: "feature-from-base",
      startPoint: "base"
    )

    #expect(FileManager.default.fileExists(atPath: path + "/BASE.md"))
  }
}

@Suite("WorktreeManagementService removal and cancellation")
struct WorktreeRemovalTests {
  @Test("Prunes stale reference when worktree directory is missing")
  func prunesWhenDirectoryMissing() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addSiblingWorktree(branch: "test-branch")
    try FileManager.default.removeItem(atPath: worktreePath)

    let service = WorktreeManagementService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath)

    let listAfter = try fixture.runGit("worktree", "list")
    #expect(!listAfter.contains("test-branch"))
  }

  @Test("Cancels in-flight worktree creation and cleans generated artifacts")
  func cancelsWorktreeCreationAndCleansUp() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try fixture.installSleepingPostCheckoutHook(seconds: 5)

    let service = WorktreeManagementService()
    let operationID = WorktreeOperationID()
    let directoryName = "cancelled-worktree"
    let branchName = "cancelled-worktree-branch"

    let task = Task {
      try await service.createWorktreeWithNewBranch(
        at: fixture.repoPath,
        newBranchName: branchName,
        directoryName: directoryName,
        operationID: operationID
      ) { _ in }
    }

    try await Task.sleep(for: .milliseconds(200))
    await service.cancelWorktreeCreation(operationID)

    await #expect(throws: WorktreeManagementError.self) {
      _ = try await task.value
    }

    let cleanup = await service.cleanupCancelledWorktreeCreation(
      repoPath: fixture.repoPath,
      newBranchName: branchName,
      directoryName: directoryName
    )

    #expect(cleanup.removedWorktree || cleanup.removedBranch || !cleanup.notes.isEmpty)
    #expect(try fixture.localBranchExists(branchName) == false)
    #expect(FileManager.default.fileExists(atPath: fixture.repoPath + "/.worktrees/\(directoryName)") == false)
  }
}
