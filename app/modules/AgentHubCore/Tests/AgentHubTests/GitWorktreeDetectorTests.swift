import Foundation
import Testing

@testable import AgentHubCore

@Suite("GitWorktreeDetector")
struct GitWorktreeDetectorTests {

  @Test("Detects a main repository with its current branch")
  func detectsMainRepository() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }

    let info = await GitWorktreeDetector.detectWorktreeInfo(for: fixture.repoPath)
    let unwrapped = try #require(info)
    #expect(unwrapped.isWorktree == false)
    #expect(unwrapped.mainRepoPath == nil)
    #expect(unwrapped.branch == "main")
  }

  @Test("Returns nil for a directory that is not a git repository")
  func returnsNilForNonRepository() async throws {
    let fixture = try Fixture(initializeGit: false)
    defer { fixture.teardown() }

    let info = await GitWorktreeDetector.detectWorktreeInfo(for: fixture.repoPath)
    #expect(info == nil)
  }

  @Test("Detects a linked worktree and resolves its main repository path")
  func detectsLinkedWorktree() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }
    let worktreePath = try fixture.addWorktree(branch: "feature-x")

    let info = await GitWorktreeDetector.detectWorktreeInfo(for: worktreePath)
    let unwrapped = try #require(info)
    #expect(unwrapped.isWorktree == true)
    #expect(unwrapped.branch == "feature-x")
    #expect(unwrapped.mainRepoPath.map { URL(fileURLWithPath: $0).standardizedFileURL.lastPathComponent }
      == URL(fileURLWithPath: fixture.repoPath).standardizedFileURL.lastPathComponent)
  }

  @Test("Lists the main worktree plus linked worktrees")
  func listsWorktrees() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }
    _ = try fixture.addWorktree(branch: "feature-y")

    let worktrees = await GitWorktreeDetector.listWorktrees(at: fixture.repoPath)
    #expect(worktrees.count == 2)
    #expect(worktrees.first?.isWorktree == false)
    #expect(worktrees.last?.isWorktree == true)
    #expect(worktrees.last?.branch == "feature-y")
  }

  @Test("Returns an empty list for a non-repository path")
  func listWorktreesOnNonRepository() async throws {
    let fixture = try Fixture(initializeGit: false)
    defer { fixture.teardown() }

    let worktrees = await GitWorktreeDetector.listWorktrees(at: fixture.repoPath)
    #expect(worktrees.isEmpty)
  }

  /// Regression guard: git exits in milliseconds, and the previous
  /// implementation installed its terminationHandler after run(), which could
  /// miss the exit and strand the call (and its pipe descriptors) forever. A
  /// concurrent burst makes that race overwhelmingly likely to fire; with
  /// per-test timeouts enabled a strand fails the suite instead of hanging.
  @Test("Concurrent detection burst completes without stranding")
  func concurrentBurstCompletes() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }

    let results = await withTaskGroup(of: GitWorktreeInfo?.self) { group in
      for _ in 0..<24 {
        group.addTask {
          await GitWorktreeDetector.detectWorktreeInfo(for: fixture.repoPath)
        }
      }
      var collected: [GitWorktreeInfo?] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    #expect(results.count == 24)
    #expect(results.allSatisfy { $0?.branch == "main" })
  }

  // MARK: - Fixture

  private struct Fixture {
    let repoPath: String

    init(initializeGit: Bool = true) throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitWorktreeDetectorTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      repoPath = root.path

      if initializeGit {
        try Self.runGit(["init", "--initial-branch=main"], in: repoPath)
        try Self.runGit(
          ["-c", "user.email=test@agenthub.dev", "-c", "user.name=AgentHub Tests",
           "commit", "--allow-empty", "-m", "init"],
          in: repoPath
        )
      }
    }

    func addWorktree(branch: String) throws -> String {
      let worktreePath = (repoPath as NSString)
        .deletingLastPathComponent + "/" + (repoPath as NSString).lastPathComponent + "-\(branch)"
      try Self.runGit(["worktree", "add", "-b", branch, worktreePath], in: repoPath)
      return worktreePath
    }

    func teardown() {
      let mainURL = URL(fileURLWithPath: repoPath)
      let parent = mainURL.deletingLastPathComponent()
      let prefix = mainURL.lastPathComponent
      if let siblings = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
        for name in siblings where name.hasPrefix(prefix) {
          try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
      }
    }

    private static func runGit(_ arguments: [String], in directory: String) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      process.currentDirectoryURL = URL(fileURLWithPath: directory)
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw FixtureError.gitCommandFailed(arguments)
      }
    }
  }

  private enum FixtureError: Error {
    case gitCommandFailed([String])
  }
}
