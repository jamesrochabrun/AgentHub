import Combine
import Foundation
import Testing

@testable import AgentHubCore

// MARK: - Private Git Fixture

private struct RemixTestGitFixture {
  let repoPath: String
  let parentDir: String

  static func create() throws -> RemixTestGitFixture {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(NSTemporaryDirectory(), &resolved) != nil else {
      throw RemixFixtureError.commandFailed
    }
    let tempBase = String(cString: resolved)
    let parentDir = tempBase + "/RemixTests-\(UUID().uuidString)"
    let repoPath = parentDir + "/repo"
    try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)

    let fixture = RemixTestGitFixture(repoPath: repoPath, parentDir: parentDir)
    try fixture.git("init", "-b", "main")
    try fixture.git("config", "user.email", "test@test.com")
    try fixture.git("config", "user.name", "Test")
    try "initial".write(toFile: repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.git("add", ".")
    try fixture.git("commit", "-m", "initial")
    return fixture
  }

  @discardableResult
  func git(_ args: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw RemixFixtureError.commandFailed
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: parentDir)
  }
}

private enum RemixFixtureError: Error {
  case commandFailed
}

// MARK: - Stubs

private actor StubMonitorService: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private actor StubFileWatcher: SessionFileWatcherProtocol {
  private nonisolated let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

// MARK: - Helpers

@MainActor
private func makeViewModel(providerKind: SessionProviderKind) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: StubMonitorService(),
    fileWatcher: StubFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(
      command: "echo",
      additionalPaths: [],
      mode: providerKind == .claude ? .claude : .codex
    ),
    providerKind: providerKind
  )
}

// MARK: - claudeProjectPathEncoded Tests

@Suite("String.claudeProjectPathEncoded")
struct ClaudeProjectPathEncodedTests {

  @Test("Replaces forward slashes with dashes")
  func replacesForwardSlashes() {
    let result = "/Users/james/Desktop/myproject".claudeProjectPathEncoded
    #expect(result == "-Users-james-Desktop-myproject")
  }

  @Test("Replaces underscores with dashes")
  func replacesUnderscores() {
    let result = "/Users/james/my_project".claudeProjectPathEncoded
    #expect(result == "-Users-james-my-project")
  }

  @Test("Replaces both slashes and underscores")
  func replacesBothSlashesAndUnderscores() {
    let result = "/home/user/some_path/my_repo".claudeProjectPathEncoded
    #expect(result == "-home-user-some-path-my-repo")
  }

  @Test("Leading slash becomes leading dash")
  func leadingSlashBecomesLeadingDash() {
    let result = "/myrepo".claudeProjectPathEncoded
    #expect(result == "-myrepo")
  }
}

// MARK: - CLISession.shortId Tests

@Suite("CLISession.shortId")
struct CLISessionShortIdTests {

  @Test("Returns first 8 characters of id")
  func returnsFirst8Chars() {
    let session = CLISession(id: "abcdef1234567890", projectPath: "/tmp/proj")
    #expect(session.shortId == "abcdef12")
  }

  @Test("Returns full id when shorter than 8 characters")
  func returnsFullIdWhenShort() {
    let session = CLISession(id: "abc", projectPath: "/tmp/proj")
    #expect(session.shortId == "abc")
  }

  @Test("Returns exactly 8 characters when id is 8 characters long")
  func returnsExact8WhenEqual() {
    let session = CLISession(id: "12345678", projectPath: "/tmp/proj")
    #expect(session.shortId == "12345678")
  }
}

// MARK: - CLISession.projectName Tests

@Suite("CLISession.projectName")
struct CLISessionProjectNameTests {

  @Test("Returns last path component")
  func returnsLastPathComponent() {
    let session = CLISession(id: "abc", projectPath: "/Users/james/Desktop/git/MyApp")
    #expect(session.projectName == "MyApp")
  }

  @Test("Returns single component for flat path")
  func singleComponent() {
    let session = CLISession(id: "abc", projectPath: "myrepo")
    #expect(session.projectName == "myrepo")
  }
}

// MARK: - remixSession Provider Routing Tests

@Suite("remixSession provider routing")
struct RemixSessionProviderRoutingTests {

  @Test("Defaults to same provider when targetProvider is nil")
  @MainActor
  func defaultsToSameProvider() async throws {
    let fixture = try RemixTestGitFixture.create()
    defer { fixture.cleanup() }

    let claudeVM = makeViewModel(providerKind: .claude)
    let session = CLISession(
      id: UUID().uuidString,
      projectPath: fixture.repoPath,
      branchName: "main",
      sessionFilePath: "\(fixture.repoPath)/session.jsonl"
    )

    claudeVM.remixSession(session)
    try await Task.sleep(for: .seconds(3))

    #expect(claudeVM.pendingHubSessions.count == 1)
  }

  @Test("Same targetProvider as providerKind routes to self")
  @MainActor
  func sameTargetProviderRoutesToSelf() async throws {
    let fixture = try RemixTestGitFixture.create()
    defer { fixture.cleanup() }

    let claudeVM = makeViewModel(providerKind: .claude)
    let session = CLISession(
      id: UUID().uuidString,
      projectPath: fixture.repoPath,
      branchName: "main",
      sessionFilePath: "\(fixture.repoPath)/session.jsonl"
    )

    claudeVM.remixSession(session, targetProvider: .claude)
    try await Task.sleep(for: .seconds(3))

    #expect(claudeVM.pendingHubSessions.count == 1)
  }

  @Test("Falls back to self when agentHubProvider is nil even with different targetProvider")
  @MainActor
  func fallsBackToSelfWithNoProvider() async throws {
    let fixture = try RemixTestGitFixture.create()
    defer { fixture.cleanup() }

    let claudeVM = makeViewModel(providerKind: .claude)
    // agentHubProvider is nil (not set), so cross-provider routing falls back to self
    let session = CLISession(
      id: UUID().uuidString,
      projectPath: fixture.repoPath,
      branchName: "main",
      sessionFilePath: "\(fixture.repoPath)/session.jsonl"
    )

    claudeVM.remixSession(session, targetProvider: .codex)
    try await Task.sleep(for: .seconds(3))

    #expect(claudeVM.pendingHubSessions.count == 1)
  }

  @Test("Routes to target ViewModel when targetProvider differs and agentHubProvider is set")
  @MainActor
  func routesToTargetViewModelWhenProviderDiffers() async throws {
    let fixture = try RemixTestGitFixture.create()
    defer { fixture.cleanup() }

    let hub = AgentHubProvider(configuration: AgentHubConfiguration(
      claudeDataPath: fixture.parentDir + "/claude",
      codexDataPath: fixture.parentDir + "/codex"
    ))
    let claudeVM = hub.claudeSessionsViewModel
    let codexVM = hub.codexSessionsViewModel

    let session = CLISession(
      id: UUID().uuidString,
      projectPath: fixture.repoPath,
      branchName: "main",
      sessionFilePath: "\(fixture.repoPath)/session.jsonl"
    )

    claudeVM.remixSession(session, targetProvider: .codex)
    try await Task.sleep(for: .seconds(3))

    #expect(claudeVM.pendingHubSessions.isEmpty)
    #expect(codexVM.pendingHubSessions.count == 1)
  }

  @Test("Pending session initialPrompt contains provided sessionFilePath")
  @MainActor
  func pendingSessionUsesSessionFilePath() async throws {
    let fixture = try RemixTestGitFixture.create()
    defer { fixture.cleanup() }

    let sessionFilePath = "\(fixture.repoPath)/sessions/abc.jsonl"
    let claudeVM = makeViewModel(providerKind: .claude)
    let session = CLISession(
      id: UUID().uuidString,
      projectPath: fixture.repoPath,
      branchName: "main",
      sessionFilePath: sessionFilePath
    )

    claudeVM.remixSession(session)
    try await Task.sleep(for: .seconds(3))

    let pending = try #require(claudeVM.pendingHubSessions.first)
    let prompt = try #require(pending.initialPrompt)
    #expect(prompt.contains(sessionFilePath))
  }

  @Test("Pending session initialPrompt falls back to encoded Claude path when sessionFilePath is nil")
  @MainActor
  func pendingSessionFallsBackToEncodedPath() async throws {
    let fixture = try RemixTestGitFixture.create()
    defer { fixture.cleanup() }

    let sessionId = UUID().uuidString
    let claudeVM = makeViewModel(providerKind: .claude)
    let session = CLISession(
      id: sessionId,
      projectPath: fixture.repoPath,
      branchName: "main",
      sessionFilePath: nil
    )

    claudeVM.remixSession(session)
    try await Task.sleep(for: .seconds(3))

    let pending = try #require(claudeVM.pendingHubSessions.first)
    let prompt = try #require(pending.initialPrompt)
    let encodedPath = fixture.repoPath.claudeProjectPathEncoded
    #expect(prompt.contains("~/.claude/projects/\(encodedPath)/\(sessionId).jsonl"))
  }
}
