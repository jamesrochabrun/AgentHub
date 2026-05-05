import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Lazy browse session loading")
@MainActor
struct LazyBrowseSessionsLoadingTests {

  @Test("Launch restores shells and monitored sessions without full browse scan")
  func launchRestoresMonitoredSessionsWithoutFullScan() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1"],
        expansionState: ["repo:/tmp/project": true]
      ),
      for: .claude
    )

    let session = CLISession(
      id: "session-1",
      projectPath: "/tmp/project",
      branchName: "main",
      firstMessage: "first",
      sessionFilePath: "/tmp/session-1.jsonl"
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])],
      sessionsById: ["session-1": session]
    )
    let watcher = RecordingFileWatcher()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: watcher,
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.monitoredSessions.count == 1
    }

    let calls = await monitor.calls()
    #expect(calls.restoreSkeletonCount == 1)
    #expect(calls.addRepositoriesCount == 0)
    #expect(calls.refreshCount == 0)
    #expect(calls.loadSessionRequests == [Set(["session-1"])])
    #expect(viewModel.selectedRepositories.map(\.path) == ["/tmp/project"])
    #expect(viewModel.monitoredSessions.first?.session.id == "session-1")
    #expect(await watcher.startedSessionIds() == ["session-1"])
  }

  @Test("Launch targeted restore skips sessions outside restored roots")
  func launchTargetedRestoreSkipsSessionsOutsideRestoredRoots() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["orphan-session", "session-1"]
      ),
      for: .claude
    )

    let session = CLISession(
      id: "session-1",
      projectPath: "/tmp/project",
      branchName: "main",
      firstMessage: "first",
      sessionFilePath: "/tmp/session-1.jsonl"
    )
    let orphan = CLISession(
      id: "orphan-session",
      projectPath: "/tmp/deleted-worktree",
      branchName: "feature",
      firstMessage: "orphan",
      sessionFilePath: "/tmp/orphan-session.jsonl"
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])],
      sessionsById: [
        "orphan-session": orphan,
        "session-1": session
      ]
    )
    let watcher = RecordingFileWatcher()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: watcher,
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.monitoredSessions.count == 1
    }

    let calls = await monitor.calls()
    #expect(calls.loadSessionRequests == [Set(["orphan-session", "session-1"])])
    #expect(viewModel.isMonitoring(sessionId: "session-1"))
    #expect(!viewModel.isMonitoring(sessionId: "orphan-session"))
    #expect(Set(viewModel.monitoredSessions.map(\.session.id)) == ["session-1"])
    #expect(await watcher.startedSessionIds() == ["session-1"])
  }

  @Test("Removing repository stops monitored sessions restored before browse load")
  func removingRepositoryStopsRestoredBackupSessionsBeforeBrowseLoad() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1"]
      ),
      for: .claude
    )

    let session = CLISession(
      id: "session-1",
      projectPath: "/tmp/project",
      branchName: "main",
      firstMessage: "first",
      sessionFilePath: "/tmp/session-1.jsonl"
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])],
      sessionsById: ["session-1": session]
    )
    let watcher = RecordingFileWatcher()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: watcher,
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.monitoredSessions.count == 1
    }

    let repository = try #require(viewModel.selectedRepositories.first)
    #expect(repository.totalSessionCount == 0)

    viewModel.removeRepository(repository)

    #expect(!viewModel.isMonitoring(sessionId: "session-1"))
    await waitUntilAsync {
      await watcher.stoppedSessionIds() == ["session-1"]
    }
  }

  @Test("Browse request during repository restore scans after repositories arrive")
  func browseRequestDuringRepositoryRestoreScansAfterRepositoriesArrive() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(selectedRepositoryPaths: ["/tmp/project"]),
      for: .codex
    )

    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])],
      restoreSkeletonDelay: .milliseconds(150)
    )

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: RecordingFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    viewModel.ensureBrowseSessionsLoaded()
    #expect(viewModel.browseSessionsLoadState == .loading)

    try await Task.sleep(for: .milliseconds(50))
    var calls = await monitor.calls()
    #expect(calls.refreshCount == 0)

    await waitUntil { viewModel.browseSessionsLoadState == .loaded }

    calls = await monitor.calls()
    #expect(calls.restoreSkeletonCount == 1)
    #expect(calls.refreshCount == 1)
    #expect(viewModel.allSessions.map(\.id) == ["session-1"])
  }

  @Test("Browse load scans once, then manual refresh scans again")
  func browseLoadScansOnceThenManualRefreshScansAgain() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(selectedRepositoryPaths: ["/tmp/project"]),
      for: .codex
    )

    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])]
    )

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: RecordingFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    #expect(viewModel.browseSessionsLoadState == .notLoaded)

    viewModel.ensureBrowseSessionsLoaded()
    await waitUntil { viewModel.browseSessionsLoadState == .loaded }

    var calls = await monitor.calls()
    #expect(calls.refreshCount == 1)
    #expect(viewModel.allSessions.map(\.id) == ["session-1"])

    viewModel.ensureBrowseSessionsLoaded()
    try await Task.sleep(for: .milliseconds(50))
    calls = await monitor.calls()
    #expect(calls.refreshCount == 1)

    viewModel.refreshBrowseSessions()
    await waitUntil { viewModel.browseSessionsLoadState == .loaded }
    calls = await monitor.calls()
    #expect(calls.refreshCount == 2)
  }

  @Test("Duplicate add keeps Browse not loaded")
  func duplicateAddKeepsBrowseNotLoaded() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(selectedRepositoryPaths: ["/tmp/project"]),
      for: .codex
    )

    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])]
    )

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: RecordingFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    #expect(viewModel.browseSessionsLoadState == .notLoaded)

    viewModel.addRepository(at: "/tmp/project")
    await waitUntilAsync {
      let calls = await monitor.calls()
      return calls.addRepositoriesCount == 1
    }
    await waitUntil { viewModel.loadingState == .idle }

    let calls = await monitor.calls()
    #expect(calls.refreshCount == 0)
    #expect(viewModel.browseSessionsLoadState == .notLoaded)
    #expect(viewModel.allSessions.isEmpty)
  }

  @Test("Claude targeted restore ignores subagent files")
  func claudeTargetedRestoreIgnoresSubagents() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let projectPath = "/tmp/project"
    let sessionId = "11111111-1111-1111-1111-111111111111"
    let projectDir = root
      .appending(path: "projects")
      .appending(path: projectPath.claudeProjectPathEncoded)
    let subagentDir = projectDir.appending(path: "subagents")
    try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)

    let mainFile = projectDir.appending(path: "\(sessionId).jsonl")
    let subagentFile = subagentDir.appending(path: "\(sessionId).jsonl")
    try claudeLine(
      sessionId: sessionId,
      cwd: projectPath,
      message: "main session",
      timestamp: "2026-05-05T12:00:00.000Z"
    ).write(to: mainFile, atomically: true, encoding: .utf8)
    try claudeLine(
      sessionId: sessionId,
      cwd: "/tmp/subagent",
      message: "subagent session",
      timestamp: "2026-05-05T12:01:00.000Z"
    ).write(to: subagentFile, atomically: true, encoding: .utf8)

    let service = CLISessionMonitorService(claudeDataPath: root.path)
    let sessions = await service.loadSessions(ids: [sessionId])

    #expect(sessions.count == 1)
    #expect(sessions.first?.projectPath == projectPath)
    #expect(sessions.first?.firstMessage == "main session")
    let sessionFilePath = try #require(sessions.first?.sessionFilePath)
    #expect(
      URL(fileURLWithPath: sessionFilePath).resolvingSymlinksInPath().path
        == mainFile.resolvingSymlinksInPath().path
    )
  }

  @Test("Codex targeted restore returns only requested sessions")
  func codexTargetedRestoreReturnsOnlyRequestedSessions() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionsDir = root
      .appending(path: "sessions")
      .appending(path: "2026")
      .appending(path: "05")
      .appending(path: "05")
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let requestedId = "22222222-2222-2222-2222-222222222222"
    let otherId = "33333333-3333-3333-3333-333333333333"
    try codexLines(sessionId: requestedId, cwd: "/tmp/project", message: "requested")
      .write(
        to: sessionsDir.appending(path: "rollout-2026-05-05T12-00-00-\(requestedId).jsonl"),
        atomically: true,
        encoding: .utf8
      )
    try codexLines(sessionId: otherId, cwd: "/tmp/other", message: "other")
      .write(
        to: sessionsDir.appending(path: "rollout-2026-05-05T12-01-00-\(otherId).jsonl"),
        atomically: true,
        encoding: .utf8
      )

    let service = CodexSessionMonitorService(codexDataPath: root.path)
    let sessions = await service.loadSessions(ids: [requestedId])

    #expect(sessions.map(\.id) == [requestedId])
    #expect(sessions.first?.firstMessage == "requested")
    #expect(sessions.first?.projectPath == "/tmp/project")
  }
}

private actor LazyBrowseMockMonitorService: SessionMonitorServiceProtocol {
  nonisolated(unsafe) private let subject = CurrentValueSubject<[SelectedRepository], Never>([])

  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  private var repositories: [SelectedRepository] = []
  private let skeletonRepositories: [SelectedRepository]
  private let browseRepositories: [SelectedRepository]
  private let sessionsById: [String: CLISession]
  private let restoreSkeletonDelay: Duration?
  private var restoreSkeletonCount = 0
  private var addRepositoriesCount = 0
  private var refreshCount = 0
  private var loadSessionRequests: [Set<String>] = []

  init(
    skeletonRepositories: [SelectedRepository],
    browseRepositories: [SelectedRepository],
    sessionsById: [String: CLISession] = [:],
    restoreSkeletonDelay: Duration? = nil
  ) {
    self.skeletonRepositories = skeletonRepositories
    self.browseRepositories = browseRepositories
    self.sessionsById = sessionsById
    self.restoreSkeletonDelay = restoreSkeletonDelay
  }

  func addRepository(_ path: String) async -> SelectedRepository? {
    addRepositoriesCount += 1
    guard !repositories.contains(where: { $0.path == path }) else {
      return nil
    }

    let repositoryToAdd = browseRepositories.first { $0.path == path }
      ?? skeletonRepositories.first { $0.path == path }
      ?? repository(path: path)
    repositories.append(repositoryToAdd)
    subject.send(repositories)
    return repositoryToAdd
  }

  func addRepositories(_ paths: [String]) async {
    addRepositoriesCount += 1
  }

  func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository] {
    if let restoreSkeletonDelay {
      try? await Task.sleep(for: restoreSkeletonDelay)
    }
    restoreSkeletonCount += 1
    repositories = skeletonRepositories
    subject.send(repositories)
    return repositories
  }

  func loadSessions(ids: Set<String>) async -> [CLISession] {
    loadSessionRequests.append(ids)
    return ids.compactMap { sessionsById[$0] }
  }

  func removeRepository(_ path: String) async {}

  func getSelectedRepositories() async -> [SelectedRepository] {
    repositories
  }

  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    self.repositories = repositories
    subject.send(repositories)
  }

  func refreshSessions(skipWorktreeRedetection: Bool) async {
    refreshCount += 1
    repositories = browseRepositories
    subject.send(repositories)
  }

  func calls() -> LazyBrowseMockCalls {
    LazyBrowseMockCalls(
      restoreSkeletonCount: restoreSkeletonCount,
      addRepositoriesCount: addRepositoriesCount,
      refreshCount: refreshCount,
      loadSessionRequests: loadSessionRequests
    )
  }
}

private struct LazyBrowseMockCalls: Sendable {
  let restoreSkeletonCount: Int
  let addRepositoriesCount: Int
  let refreshCount: Int
  let loadSessionRequests: [Set<String>]
}

private actor RecordingFileWatcher: SessionFileWatcherProtocol {
  nonisolated(unsafe) private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  private var started: [String] = []
  private var stopped: [String] = []

  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {
    started.append(sessionId)
  }

  func stopMonitoring(sessionId: String) async {
    stopped.append(sessionId)
  }
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}

  func startedSessionIds() -> [String] {
    started
  }

  func stoppedSessionIds() -> [String] {
    stopped
  }
}

private func repository(path: String, sessions: [CLISession] = []) -> SelectedRepository {
  SelectedRepository(
    path: path,
    worktrees: [
      WorktreeBranch(name: "main", path: path, isWorktree: false, sessions: sessions)
    ]
  )
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(2),
  condition: @escaping @MainActor () -> Bool
) async {
  let start = ContinuousClock.now
  while !condition(), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition())
}

private func waitUntilAsync(
  timeout: Duration = .seconds(2),
  condition: @escaping () async -> Bool
) async {
  let start = ContinuousClock.now
  while !(await condition()), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(await condition())
}

private func temporaryDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "lazy_browse_\(UUID().uuidString).sqlite")
    .path
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "lazy_browse_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func claudeLine(
  sessionId: String,
  cwd: String,
  message: String,
  timestamp: String
) -> String {
  """
  {"sessionId":"\(sessionId)","cwd":"\(cwd)","gitBranch":"main","slug":"test-slug","type":"user","timestamp":"\(timestamp)","message":{"role":"user","content":"\(message)"}}

  """
}

private func codexLines(sessionId: String, cwd: String, message: String) -> String {
  """
  {"timestamp":"2026-05-05T12:00:00.000Z","type":"session_meta","payload":{"id":"\(sessionId)","timestamp":"2026-05-05T12:00:00.000Z","cwd":"\(cwd)","git":{"branch":"main"}}}
  {"timestamp":"2026-05-05T12:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"\(message)"}}

  """
}
