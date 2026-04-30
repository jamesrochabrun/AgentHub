import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session monitor repository roots")
struct SessionMonitorRepositoryRootTests {
  @Test("Claude monitor stores the root repository when adding a linked worktree")
  func claudeMonitorStoresRootRepositoryForLinkedWorktree() async throws {
    let fixture = try GitRepositoryRootFixture.create()
    defer { fixture.cleanUp() }
    let worktreePath = try fixture.addWorktree(branch: "feature/root-header")
    let dataPath = try fixture.makeDataPath(named: "claude")

    let service = CLISessionMonitorService(claudeDataPath: dataPath.path)
    let returnedRepository = await service.addRepository(worktreePath)
    let repositories = await service.getSelectedRepositories()

    #expect(returnedRepository?.path == fixture.repoPath)
    #expect(repositories.map(\.path) == [fixture.repoPath])
    #expect(repositories.first?.worktrees.contains { $0.path == worktreePath } == true)
  }

  @Test("Codex monitor stores the root repository when adding a linked worktree")
  func codexMonitorStoresRootRepositoryForLinkedWorktree() async throws {
    let fixture = try GitRepositoryRootFixture.create()
    defer { fixture.cleanUp() }
    let worktreePath = try fixture.addWorktree(branch: "feature/root-header")
    let dataPath = try fixture.makeDataPath(named: "codex")

    let service = CodexSessionMonitorService(codexDataPath: dataPath.path)
    let returnedRepository = await service.addRepository(worktreePath)
    let repositories = await service.getSelectedRepositories()

    #expect(returnedRepository?.path == fixture.repoPath)
    #expect(repositories.map(\.path) == [fixture.repoPath])
    #expect(repositories.first?.worktrees.contains { $0.path == worktreePath } == true)
  }
}

private struct GitRepositoryRootFixture {
  let parentURL: URL
  let repoURL: URL

  var repoPath: String { repoURL.path }

  static func create() throws -> GitRepositoryRootFixture {
    let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
      .resolvingSymlinksInPath()
    let parentURL = tempBase
      .appendingPathComponent("AgentHubRootTests-\(UUID().uuidString)", isDirectory: true)
    let repoURL = parentURL.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

    let fixture = GitRepositoryRootFixture(parentURL: parentURL, repoURL: repoURL)
    try fixture.runGit("init", "-b", "main")
    try fixture.runGit("config", "user.email", "test@example.com")
    try fixture.runGit("config", "user.name", "Test User")
    try "initial\n".write(
      to: repoURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "initial")
    return fixture
  }

  func addWorktree(branch: String) throws -> String {
    try runGit("branch", branch)
    let safeDirectoryName = branch.replacingOccurrences(of: "/", with: "-")
    let worktreeURL = parentURL.appendingPathComponent(safeDirectoryName, isDirectory: true)
    try runGit("worktree", "add", worktreeURL.path, branch)
    return worktreeURL.path
  }

  func makeDataPath(named name: String) throws -> URL {
    let url = parentURL.appendingPathComponent(".\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: parentURL)
  }

  @discardableResult
  func runGit(_ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = repoURL

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = String(
      data: stdout.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorOutput = String(
      data: stderr.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if process.terminationStatus != 0 {
      throw GitRepositoryRootFixtureError.commandFailed(
        command: arguments.joined(separator: " "),
        output: output,
        error: errorOutput
      )
    }

    return output
  }
}

private enum GitRepositoryRootFixtureError: Error, CustomStringConvertible {
  case commandFailed(command: String, output: String, error: String)

  var description: String {
    switch self {
    case .commandFailed(let command, let output, let error):
      return "git \(command) failed\nstdout: \(output)\nstderr: \(error)"
    }
  }
}
