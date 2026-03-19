import Foundation
import Combine
import Testing

@testable import AgentHubCore

// MARK: - Mocks

private final class MockMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  let subject = PassthroughSubject<[SelectedRepository], Never>()
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func addRepositories(_ paths: [String]) async {}
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class MockFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

// MARK: - Helpers

private let testProjectPath = "/tmp/test-project"

private func makeSession(id: String = UUID().uuidString, projectPath: String = testProjectPath) -> CLISession {
  CLISession(
    id: id,
    projectPath: projectPath,
    branchName: "main",
    isWorktree: false,
    lastActivityAt: Date(),
    messageCount: 1,
    isActive: true
  )
}

private func makeWorktree(
  path: String = testProjectPath,
  sessions: [CLISession] = []
) -> WorktreeBranch {
  WorktreeBranch(
    name: "main",
    path: path,
    isWorktree: false,
    sessions: sessions,
    isExpanded: true
  )
}

private func makeRepo(
  path: String = testProjectPath,
  worktrees: [WorktreeBranch] = []
) -> SelectedRepository {
  SelectedRepository(
    path: path,
    worktrees: worktrees,
    isExpanded: true
  )
}

@MainActor
private func makeViewModel(
  sessions: [CLISession] = [],
  projectPath: String = testProjectPath
) -> (CLISessionsViewModel, MockFileWatcher) {
  let monitorService = MockMonitorService()
  let fileWatcher = MockFileWatcher()

  let vm = CLISessionsViewModel(
    monitorService: monitorService,
    fileWatcher: fileWatcher,
    searchService: nil,
    cliConfiguration: .claudeDefault,
    providerKind: .claude
  )

  // Pre-populate selectedRepositories with a worktree containing the test sessions
  let worktree = makeWorktree(path: projectPath, sessions: sessions)
  let repo = makeRepo(path: projectPath, worktrees: [worktree])
  vm.selectedRepositories = [repo]

  return (vm, fileWatcher)
}

// MARK: - Suite 1: TransferMonitoringTests

@Suite("transferMonitoring — core state re-keying")
struct TransferMonitoringTests {

  @Test("Transfers monitoring IDs from old to new session")
  @MainActor
  func transfersMonitoringIds() {
    let oldSession = makeSession(id: "old-session")
    let newSession = makeSession(id: "new-session")
    let (vm, _) = makeViewModel(sessions: [oldSession, newSession])

    vm.startMonitoring(session: oldSession)
    #expect(vm.monitoredSessionIds.contains("old-session"))

    vm.transferMonitoring(fromSessionId: "old-session", toSessionId: "new-session")

    #expect(!vm.monitoredSessionIds.contains("old-session"))
    #expect(vm.monitoredSessionIds.contains("new-session"))
  }

  @Test("Transfers terminal view state from old to new session")
  @MainActor
  func transfersTerminalViewState() {
    let oldSession = makeSession(id: "old-session")
    let newSession = makeSession(id: "new-session")
    let (vm, _) = makeViewModel(sessions: [oldSession, newSession])

    vm.startMonitoring(session: oldSession)
    // startMonitoring defaults to terminal view
    #expect(vm.sessionsWithTerminalView.contains("old-session"))

    vm.transferMonitoring(fromSessionId: "old-session", toSessionId: "new-session")

    #expect(!vm.sessionsWithTerminalView.contains("old-session"))
    #expect(vm.sessionsWithTerminalView.contains("new-session"))
  }

  @Test("Transfers custom name from old to new session")
  @MainActor
  func transfersCustomName() {
    let oldSession = makeSession(id: "old-session")
    let newSession = makeSession(id: "new-session")
    let (vm, _) = makeViewModel(sessions: [oldSession, newSession])

    vm.startMonitoring(session: oldSession)
    vm.sessionCustomNames["old-session"] = "My Task"

    vm.transferMonitoring(fromSessionId: "old-session", toSessionId: "new-session")

    #expect(vm.sessionCustomNames["old-session"] == nil)
    #expect(vm.sessionCustomNames["new-session"] == "My Task")
  }

  @Test("Transfers pending prompt from old to new session")
  @MainActor
  func transfersPendingPrompt() {
    let oldSession = makeSession(id: "old-session")
    let newSession = makeSession(id: "new-session")
    let (vm, _) = makeViewModel(sessions: [oldSession, newSession])

    vm.startMonitoring(session: oldSession)
    vm.pendingTerminalPrompts["old-session"] = "fix the bug"

    vm.transferMonitoring(fromSessionId: "old-session", toSessionId: "new-session")

    #expect(vm.pendingTerminalPrompts["old-session"] == nil)
    #expect(vm.pendingTerminalPrompts["new-session"] == "fix the bug")
  }

  @Test("Populates resolvedContinuations mapping")
  @MainActor
  func populatesResolvedContinuations() {
    let oldSession = makeSession(id: "old-session")
    let newSession = makeSession(id: "new-session")
    let (vm, _) = makeViewModel(sessions: [oldSession, newSession])

    vm.startMonitoring(session: oldSession)
    vm.transferMonitoring(fromSessionId: "old-session", toSessionId: "new-session")

    #expect(vm.resolvedContinuations["old-session"] == "new-session")
  }

  @Test("Clears old monitor state after transfer")
  @MainActor
  func clearsOldMonitorState() {
    let oldSession = makeSession(id: "old-session")
    let newSession = makeSession(id: "new-session")
    let (vm, _) = makeViewModel(sessions: [oldSession, newSession])

    vm.startMonitoring(session: oldSession)
    vm.monitorStates["old-session"] = SessionMonitorState(status: .thinking)

    vm.transferMonitoring(fromSessionId: "old-session", toSessionId: "new-session")

    #expect(vm.monitorStates["old-session"] == nil)
  }

  @Test("No-op when old session is not monitored")
  @MainActor
  func noOpWhenOldSessionNotMonitored() {
    let session = makeSession(id: "some-session")
    let (vm, _) = makeViewModel(sessions: [session])

    // Should not crash or mutate state
    vm.transferMonitoring(fromSessionId: "unknown-id", toSessionId: "new-id")

    #expect(vm.monitoredSessionIds.isEmpty)
    #expect(vm.resolvedContinuations.isEmpty)
  }

  @Test("No-op when old session is monitored but not in backup and new session not in allSessions")
  @MainActor
  func noOpWhenOldSessionNotInBackup() {
    let (vm, _) = makeViewModel()

    // Manually insert into monitoredSessionIds without going through startMonitoring
    // (which would also populate backup)
    vm.monitoredSessionIds.insert("orphan-id")

    // The old session is monitored but has no backup entry and "new-id" is not in allSessions
    vm.transferMonitoring(fromSessionId: "orphan-id", toSessionId: "new-id")

    // Should have returned early — orphan-id still in monitoredSessionIds because
    // the guard passes but the else branch returns early
    #expect(vm.resolvedContinuations.isEmpty)
  }

  @Test("Creates session from backup when not in allSessions and inserts into repository")
  @MainActor
  func createsSessionFromBackupWhenNotInAllSessions() {
    let oldSession = makeSession(id: "old-session")
    let (vm, _) = makeViewModel(sessions: [oldSession])

    vm.startMonitoring(session: oldSession)

    // "new-session" is NOT in allSessions — should be created from backup metadata
    vm.transferMonitoring(fromSessionId: "old-session", toSessionId: "new-session")

    #expect(vm.monitoredSessionIds.contains("new-session"))
    #expect(!vm.monitoredSessionIds.contains("old-session"))

    // The new session should have been inserted into the repository
    let repoSessions = vm.selectedRepositories.flatMap { $0.worktrees.flatMap { $0.sessions } }
    #expect(repoSessions.contains(where: { $0.id == "new-session" }))

    // Verify the created session inherits properties from the old session
    let created = repoSessions.first(where: { $0.id == "new-session" })
    #expect(created?.projectPath == testProjectPath)
    #expect(created?.isActive == true)
  }
}

// MARK: - Suite 2: InsertSessionIntoRepositoryTests

@Suite("insertSessionIntoRepository — sidebar tree insertion")
struct InsertSessionIntoRepositoryTests {

  @Test("Inserts session into matching worktree")
  @MainActor
  func insertsIntoMatchingWorktree() {
    let (vm, _) = makeViewModel()

    let session = makeSession(id: "inserted-session")
    vm.insertSessionIntoRepository(session)

    let worktreeSessions = vm.selectedRepositories[0].worktrees[0].sessions
    #expect(worktreeSessions.contains(where: { $0.id == "inserted-session" }))
  }

  @Test("Does not create duplicates when called twice")
  @MainActor
  func avoidsDuplicates() {
    let (vm, _) = makeViewModel()

    let session = makeSession(id: "dup-session")
    vm.insertSessionIntoRepository(session)
    vm.insertSessionIntoRepository(session)

    let matchCount = vm.selectedRepositories[0].worktrees[0].sessions.filter { $0.id == "dup-session" }.count
    #expect(matchCount == 1)
  }

  @Test("No-op when no matching worktree exists")
  @MainActor
  func noOpWhenNoMatchingWorktree() {
    let (vm, _) = makeViewModel()

    let session = makeSession(id: "orphan", projectPath: "/tmp/no-such-project")
    let countBefore = vm.selectedRepositories[0].worktrees[0].sessions.count
    vm.insertSessionIntoRepository(session)
    let countAfter = vm.selectedRepositories[0].worktrees[0].sessions.count

    #expect(countBefore == countAfter)
  }
}

// MARK: - Suite 3: SyncMonitoredSessionBackupTests

@Suite("syncMonitoredSessionBackup — timing guard and cleanup")
struct SyncMonitoredSessionBackupTests {

  @Test("Does not clear backup while pending restorations exist")
  @MainActor
  func doesNotClearBackupDuringPendingRestorations() {
    let session = makeSession(id: "persisted-session")
    let (vm, _) = makeViewModel(sessions: [session])

    // Populate backup via startMonitoring
    vm.startMonitoring(session: session)
    #expect(vm.monitoredSessionBackup["persisted-session"] != nil)

    // Simulate pending restoration (as if app just relaunched)
    vm.pendingRestorationSessionIds = ["some-other-session"]

    // syncMonitoredSessionBackup should bail out early
    vm.syncMonitoredSessionBackup()

    // Backup should be untouched
    #expect(vm.monitoredSessionBackup["persisted-session"] != nil)
  }

  @Test("Cleans orphaned backup entries after restorations complete")
  @MainActor
  func cleansOrphanedBackupAfterRestorationsComplete() {
    let session = makeSession(id: "monitored-session")
    let (vm, _) = makeViewModel(sessions: [session])

    // Start monitoring to populate backup
    vm.startMonitoring(session: session)

    // Stop monitoring — removes from monitoredSessionIds but backup persists until sync
    vm.stopMonitoring(sessionId: "monitored-session")
    // Re-add to backup manually to simulate a stale entry
    vm.monitoredSessionBackup["monitored-session"] = session

    // Ensure no pending restorations
    vm.pendingRestorationSessionIds = []

    // Now sync should clean the orphaned entry
    vm.syncMonitoredSessionBackup()

    #expect(vm.monitoredSessionBackup["monitored-session"] == nil)
  }

  @Test("Updates backup with latest session data for monitored sessions")
  @MainActor
  func updatesBackupWithLatestSessionData() {
    let session = makeSession(id: "active-session")
    let (vm, _) = makeViewModel(sessions: [session])

    vm.startMonitoring(session: session)

    // Update the session in selectedRepositories with new data
    var updatedSession = session
    updatedSession.messageCount = 42
    vm.selectedRepositories[0].worktrees[0].sessions = [updatedSession]

    vm.pendingRestorationSessionIds = []
    vm.syncMonitoredSessionBackup()

    #expect(vm.monitoredSessionBackup["active-session"]?.messageCount == 42)
  }
}

// MARK: - Suite 4: ContinuationViaPublisherTests

@Suite("Continuation via statePublisher — end-to-end flow")
struct ContinuationViaPublisherTests {

  @Test("Continuation event triggers transfer via publisher subscription")
  @MainActor
  func continuationEventTriggersTransfer() async throws {
    let oldSession = makeSession(id: "old-pub")
    let newSession = makeSession(id: "new-pub")
    let (vm, mockWatcher) = makeViewModel(sessions: [oldSession, newSession])

    vm.startMonitoring(session: oldSession)
    #expect(vm.monitoredSessionIds.contains("old-pub"))

    // Emit a continuation event from the mock file watcher
    let state = SessionMonitorState(status: .idle)
    mockWatcher.subject.send(
      SessionFileWatcher.StateUpdate(
        sessionId: "old-pub",
        state: state,
        continuationSessionId: "new-pub"
      )
    )

    // Allow the Combine pipeline + Task to settle
    try await Task.sleep(for: .milliseconds(500))

    #expect(!vm.monitoredSessionIds.contains("old-pub"))
    #expect(vm.monitoredSessionIds.contains("new-pub"))
    #expect(vm.resolvedContinuations["old-pub"] == "new-pub")
  }

  @Test("Normal update does not trigger transfer")
  @MainActor
  func normalUpdateDoesNotTriggerTransfer() async throws {
    let session = makeSession(id: "normal-session")
    let (vm, mockWatcher) = makeViewModel(sessions: [session])

    vm.startMonitoring(session: session)

    let state = SessionMonitorState(status: .thinking, messageCount: 5)
    mockWatcher.subject.send(
      SessionFileWatcher.StateUpdate(
        sessionId: "normal-session",
        state: state,
        continuationSessionId: nil
      )
    )

    // Allow Combine pipeline to settle
    try await Task.sleep(for: .milliseconds(100))

    #expect(vm.monitoredSessionIds.contains("normal-session"))
    #expect(vm.monitorStates["normal-session"]?.status == .thinking)
    #expect(vm.monitorStates["normal-session"]?.messageCount == 5)
    #expect(vm.resolvedContinuations.isEmpty)
  }
}
