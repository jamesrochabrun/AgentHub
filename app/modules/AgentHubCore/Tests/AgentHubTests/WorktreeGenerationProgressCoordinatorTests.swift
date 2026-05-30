import AgentHubCLIKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("WorktreeGenerationProgressCoordinator")
struct WorktreeGenerationProgressCoordinatorTests {

  @Test("Side-panel completion fires sound and notification once")
  func sidePanelCompletionFires() async {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)

    coord.beginSidePanelOperation(branchName: "feature/x", repoName: "repo", providerKind: .claude) { onProgress in
      await onProgress(.updatingFiles(current: 1, total: 2))
      await onProgress(.completed(path: "/tmp/repo/.worktrees/x"))
    }

    try? await Task.sleep(for: .milliseconds(1100))

    #expect(notif.calls == [["feature/x"]])
    #expect(sound.count == 1)
  }

  @Test("Side-panel and MCP completions fire once with both branches")
  func mixedCompletionFiresOnce() async {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let watcher = MockProgressWatcher()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)
    coord.startObservingMCP(watcher: watcher)

    // Keep an MCP op in-flight so the side-panel completion can't fire early.
    watcher.send(snapshot("mcp-1", "mcp/work", .updatingFiles(current: 1, total: 10), at: 1))
    await settle()

    coord.beginSidePanelOperation(branchName: "feature/x", repoName: "repo", providerKind: .claude) { onProgress in
      await onProgress(.completed(path: "/tmp/repo/.worktrees/x"))
    }
    try? await Task.sleep(for: .milliseconds(200))
    #expect(notif.calls.isEmpty)

    watcher.send(snapshot("mcp-1", "mcp/work", .completed(path: "/tmp/repo/.worktrees/mcp"), at: 2))
    try? await Task.sleep(for: .milliseconds(1100))

    #expect(sound.count == 1)
    #expect(notif.calls.count == 1)
    #expect(Set(notif.calls.first ?? []) == ["feature/x", "mcp/work"])
  }

  @Test("Launch-flow progress is tracked and fires once on completion")
  func launchProgressFires() async {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)

    coord.reportLaunchProgress(operationID: "L1", branchName: "add-logging", repoName: "repo", providerKind: .claude, progress: .updatingFiles(current: 1, total: 4))
    #expect(coord.operations.count == 1)
    #expect(coord.inFlightCount == 1)

    coord.reportLaunchProgress(operationID: "L1", branchName: "add-logging", repoName: "repo", providerKind: .claude, progress: .completed(path: "/tmp/repo/.worktrees/add-logging"))
    try? await Task.sleep(for: .milliseconds(1100))

    #expect(sound.count == 1)
    #expect(notif.calls == [["add-logging"]])
  }

  @Test("Branch naming shows a transient row that never announces ready")
  func namingDoesNotFireReady() async {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)

    coord.reportNamingProgress(operationID: "N1", repoName: "repo", providerKind: .claude, progress: .preparingContext(message: "Preparing"))
    #expect(coord.operations.count == 1)
    #expect(coord.inFlightCount == 1)
    #expect(coord.operations.first?.isNaming == true)

    coord.reportNamingProgress(operationID: "N1", repoName: "repo", providerKind: .claude, progress: .completed(message: "ready", source: .ai, branchNames: ["feature/x"]))
    try? await Task.sleep(for: .milliseconds(900))

    // Naming on its own must never play the sound or post the notification.
    #expect(sound.count == 0)
    #expect(notif.calls.isEmpty)
  }

  @Test("Naming + creation announces a single ready worktree, not two")
  func namingPlusCreationCountsOnce() async {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)

    // The transient naming step followed by the real creation, same worktree.
    coord.reportNamingProgress(operationID: "N1", repoName: "repo", providerKind: .claude, progress: .preparingContext(message: "Preparing"))
    coord.reportNamingProgress(operationID: "N1", repoName: "repo", providerKind: .claude, progress: .completed(message: "ready", source: .ai, branchNames: ["feature/x"]))
    coord.reportLaunchProgress(operationID: "C1", branchName: "feature/x", repoName: "repo", providerKind: .claude, progress: .updatingFiles(current: 1, total: 4))
    coord.reportLaunchProgress(operationID: "C1", branchName: "feature/x", repoName: "repo", providerKind: .claude, progress: .completed(path: "/tmp/x"))
    try? await Task.sleep(for: .milliseconds(1100))

    #expect(sound.count == 1)
    #expect(notif.calls == [["feature/x"]])
  }

  @Test("Failure does not fire ready and keeps the entry visible")
  func failureDoesNotFire() async {
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)

    struct Boom: Error {}
    coord.beginSidePanelOperation(branchName: "feature/x", repoName: "repo", providerKind: .claude) { _ in
      throw Boom()
    }

    try? await Task.sleep(for: .milliseconds(1100))

    #expect(sound.count == 0)
    #expect(notif.calls.isEmpty)
    #expect(coord.operations.count == 1)
    #expect(coord.hasFailures)
  }

  @Test("dismissAllFailed clears failed operations")
  func dismissAllFailedClears() async {
    let coord = WorktreeGenerationProgressCoordinator(soundService: MockSound(), notificationService: MockNotifier())

    struct Boom: Error {}
    coord.beginSidePanelOperation(branchName: "feature/x", repoName: "repo", providerKind: .claude) { _ in
      throw Boom()
    }
    try? await Task.sleep(for: .milliseconds(200))
    #expect(coord.hasFailures)
    #expect(coord.operations.count == 1)

    coord.dismissAllFailed()
    #expect(coord.operations.isEmpty)
    #expect(!coord.hasFailures)
  }

  @Test("Sequential MCP completions fire once, not per-worktree (debounce)")
  func sequentialMCPFiresOnce() async {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let watcher = MockProgressWatcher()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)
    coord.startObservingMCP(watcher: watcher)

    watcher.send(snapshot("op-1", "b1", .updatingFiles(current: 1, total: 10), at: 1))
    await settle()
    watcher.send(snapshot("op-1", "b1", .completed(path: "/tmp/1"), at: 2))
    await settle() // momentary idle — must NOT fire because op-2 starts within the debounce window
    watcher.send(snapshot("op-2", "b2", .updatingFiles(current: 1, total: 10), at: 3))
    await settle()
    watcher.send(snapshot("op-2", "b2", .completed(path: "/tmp/2"), at: 4))
    try? await Task.sleep(for: .milliseconds(1100))

    #expect(sound.count == 1)
    #expect(notif.calls.count == 1)
    #expect(Set(notif.calls.first ?? []) == ["b1", "b2"])
  }

  @Test("Dismiss removes the operation and discards its MCP snapshot")
  func dismissRemovesAndDiscards() async {
    let watcher = MockProgressWatcher()
    let coord = WorktreeGenerationProgressCoordinator(soundService: MockSound(), notificationService: MockNotifier())
    coord.startObservingMCP(watcher: watcher)

    watcher.send(snapshot("op-1", "b1", .failed(error: "nope"), at: 1))
    await settle()
    #expect(coord.operations.count == 1)

    coord.dismiss(id: "op-1")
    await settle()

    #expect(coord.operations.isEmpty)
    #expect(watcher.discarded == ["op-1"])
  }

  // MARK: - Helpers

  private func snapshot(
    _ id: String,
    _ branch: String,
    _ progress: WorktreeCreationProgress,
    at seconds: TimeInterval
  ) -> WorktreeProgressSnapshot {
    WorktreeProgressSnapshot(
      operationID: id,
      branchName: branch,
      repositoryPath: "/tmp/repo",
      provider: .codex,
      progress: progress,
      updatedAt: Date(timeIntervalSince1970: seconds)
    )
  }

  private func settle() async {
    try? await Task.sleep(for: .milliseconds(40))
  }
}

// MARK: - Mocks

private final class MockSound: WorktreeSuccessSoundServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var _count = 0
  var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
  func playWorktreeCreatedSound() async {
    lock.lock(); _count += 1; lock.unlock()
  }
}

private final class MockNotifier: WorktreeReadyNotificationServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var _calls: [[String]] = []
  var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
  func requestPermission() async -> Bool { true }
  func notifyReady(branchNames: [String]) {
    lock.lock(); _calls.append(branchNames); lock.unlock()
  }
}

private final class MockProgressWatcher: WorktreeProgressSidecarWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<WorktreeProgressSnapshot, Never>()
  var updates: AnyPublisher<WorktreeProgressSnapshot, Never> { subject.eraseToAnyPublisher() }

  private let lock = NSLock()
  private var _discarded: [String] = []
  var discarded: [String] { lock.lock(); defer { lock.unlock() }; return _discarded }

  func start() async {}
  func wipeAll() async {}
  func discardSnapshot(operationID: String) async {
    lock.lock(); _discarded.append(operationID); lock.unlock()
  }

  func send(_ snapshot: WorktreeProgressSnapshot) {
    subject.send(snapshot)
  }
}
