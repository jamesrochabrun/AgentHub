import Foundation
import Testing
import AgentHubGitHub

@testable import AgentHubCore
@testable import AgentHubGlobalSessionPanel

@MainActor
private final class MockGlobalHotKeyRegistrar: GlobalHotKeyRegistrarProtocol {
  var onHotKeyPressed: (@MainActor @Sendable () -> Void)?
  private(set) var registeredHotKeys: [GlobalHotKey] = []
  private(set) var unregisterCallCount = 0
  var registrationError: Error?

  var isRegistered: Bool {
    !registeredHotKeys.isEmpty
  }

  func register(hotKey: GlobalHotKey) throws {
    if let registrationError {
      throw registrationError
    }
    registeredHotKeys.append(hotKey)
  }

  func unregister() {
    unregisterCallCount += 1
    registeredHotKeys.removeAll()
  }

  func fire() {
    onHotKeyPressed?()
  }
}

@MainActor
private final class MockGlobalSessionControlPanelPresenter: GlobalSessionControlPanelPresenting {
  private(set) var showCallCount = 0
  private(set) var hideCallCount = 0
  private(set) var isVisible = false

  func show() {
    showCallCount += 1
    isVisible = true
  }

  func hide() {
    hideCallCount += 1
    isVisible = false
  }
}

@Suite("Global session control panel")
@MainActor
struct GlobalSessionControlPanelTests {
  @Test("Default shortcut is Command Option B")
  func defaultShortcutMatchesSessionPanelBinding() {
    #expect(GlobalHotKey.sessionControlPanelDefault.displayString == "⌘⌥B")
  }

  @Test("Coordinator registers only when enabled and unregisters when disabled")
  func coordinatorHonorsEnabledPreference() {
    let defaults = makeDefaults()
    let registrar = MockGlobalHotKeyRegistrar()
    let presenter = MockGlobalSessionControlPanelPresenter()
    let coordinator = GlobalSessionControlPanelCoordinator(
      registrar: registrar,
      presenter: presenter,
      defaults: defaults
    )

    coordinator.start()
    #expect(registrar.registeredHotKeys.isEmpty)

    coordinator.setEnabled(true)
    #expect(registrar.registeredHotKeys == [.sessionControlPanelDefault])
    #expect(coordinator.registrationErrorMessage == nil)

    coordinator.setEnabled(false)
    #expect(registrar.registeredHotKeys.isEmpty)
    #expect(registrar.unregisterCallCount >= 1)
  }

  @Test("Coordinator honors registered default enabled preference")
  func coordinatorHonorsRegisteredDefaultEnabledPreference() {
    let defaults = makeDefaults()
    defaults.register(defaults: [
      AgentHubDefaults.globalSessionPanelEnabled: true
    ])
    let registrar = MockGlobalHotKeyRegistrar()
    let presenter = MockGlobalSessionControlPanelPresenter()
    let coordinator = GlobalSessionControlPanelCoordinator(
      registrar: registrar,
      presenter: presenter,
      defaults: defaults
    )

    coordinator.start()

    #expect(registrar.registeredHotKeys == [.sessionControlPanelDefault])
  }

  @Test("Coordinator hotkey callback toggles the presenter")
  func hotKeyCallbackTogglesPanel() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: AgentHubDefaults.globalSessionPanelEnabled)
    let registrar = MockGlobalHotKeyRegistrar()
    let presenter = MockGlobalSessionControlPanelPresenter()
    let coordinator = GlobalSessionControlPanelCoordinator(
      registrar: registrar,
      presenter: presenter,
      defaults: defaults
    )

    coordinator.start()
    registrar.fire()
    #expect(presenter.showCallCount == 1)
    #expect(coordinator.isPanelVisible)

    registrar.fire()
    #expect(presenter.hideCallCount == 1)
    #expect(!coordinator.isPanelVisible)
  }

  @Test("Coordinator stores registration failures without presenting")
  func registrationFailureIsStored() {
    let defaults = makeDefaults()
    let registrar = MockGlobalHotKeyRegistrar()
    registrar.registrationError = GlobalHotKeyRegistrationError.registerFailed(status: -9876)
    let presenter = MockGlobalSessionControlPanelPresenter()
    let coordinator = GlobalSessionControlPanelCoordinator(
      registrar: registrar,
      presenter: presenter,
      defaults: defaults
    )

    coordinator.setEnabled(true)

    #expect(registrar.registeredHotKeys.isEmpty)
    #expect(coordinator.registrationErrorMessage?.contains("-9876") == true)
    #expect(!presenter.isVisible)
  }

  @Test("Selection router maps provider sessions to main-app item ids")
  func selectionRouterBuildsProviderScopedItemID() {
    let router = GlobalSessionSelectionRouter()

    router.select(providerKind: .codex, sessionId: "session-123", projectPath: "/tmp/repo")

    let request = router.selectionRequest
    #expect(request?.itemId == "codex-session-123")
    #expect(request?.providerKind == .codex)
    #expect(request?.projectPath == "/tmp/repo")

    if let request {
      router.markConsumed(request)
    }
    #expect(router.selectionRequest == nil)
  }

  @Test("Selection router preserves explicit pending item ids")
  func selectionRouterPreservesPendingItemID() {
    let router = GlobalSessionSelectionRouter()
    let pendingItemID = "pending-claude-7F6A9A1B-CC2A-4C74-8C7D-1E220B571111"

    router.select(
      providerKind: .claude,
      sessionId: "pending-7F6A9A1B-CC2A-4C74-8C7D-1E220B571111",
      projectPath: "/tmp/repo",
      itemId: pendingItemID
    )

    #expect(router.selectionRequest?.itemId == pendingItemID)
  }

  @Test("Snapshot ordering prioritizes attention before recency")
  func snapshotOrderingPrioritizesAttention() {
    let base = Date(timeIntervalSince1970: 1_000)
    let items = [
      item(id: "idle-new", seconds: 50, status: .idle),
      item(id: "approval-old", seconds: 10, status: .awaitingApproval(tool: "Bash")),
      item(id: "working", seconds: 40, status: .thinking),
      item(id: "ci-failure", seconds: 20, status: .waitingForUser, ciStatus: .failure),
      item(id: "pending-ci", seconds: 30, status: .idle, ciStatus: .pending),
      item(id: "ready", seconds: 60, status: .waitingForUser),
    ].map { original in
      GlobalSessionControlPanelItem(
        id: original.id,
        session: CLISession(
          id: original.id,
          projectPath: "/tmp/repo",
          branchName: "main",
          lastActivityAt: base.addingTimeInterval(original.seconds)
        ),
        providerKind: .claude,
        timestamp: base.addingTimeInterval(original.seconds),
        isPending: false,
        status: original.status,
        linkedPullRequestNumber: nil,
        customName: nil,
        gitHubState: original.ciStatus.map {
          GlobalSessionControlPanelGitHubState(hasPullRequest: true, ciStatus: $0)
        }
      )
    }

    let sorted = GlobalSessionControlPanelSnapshotBuilder.sorted(items)

    #expect(sorted.map(\.id) == [
      "approval-old",
      "ci-failure",
      "working",
      "pending-ci",
      "ready",
      "idle-new",
    ])
  }

  @Test("Keyboard navigation moves selection and clamps at the list edges")
  func keyboardNavigationClampsAtEdges() {
    let ids = ["a", "b", "c"]

    // No current selection: down lands on the first row, up lands on the last.
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: nil, direction: .down, itemIDs: ids) == "a")
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: nil, direction: .up, itemIDs: ids) == "c")

    // Moving down advances one row at a time.
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: "a", direction: .down, itemIDs: ids) == "b")
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: "b", direction: .down, itemIDs: ids) == "c")

    // Down clamps at the bottom, up clamps at the top.
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: "c", direction: .down, itemIDs: ids) == "c")
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: "b", direction: .up, itemIDs: ids) == "a")
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: "a", direction: .up, itemIDs: ids) == "a")

    // A stale selection falls back to an edge instead of returning nothing.
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: "z", direction: .down, itemIDs: ids) == "a")

    // An empty list never yields a selection.
    #expect(GlobalSessionPanelNavigator.nextSelection(currentID: "a", direction: .down, itemIDs: []) == nil)
  }

  @Test("Selection validation keeps valid rows and recovers from removals")
  func validatedSelectionRecoversFromRemovals() {
    #expect(GlobalSessionPanelNavigator.validatedSelection(currentID: "b", itemIDs: ["a", "b", "c"]) == "b")
    #expect(GlobalSessionPanelNavigator.validatedSelection(currentID: "x", itemIDs: ["a", "b", "c"]) == "a")
    #expect(GlobalSessionPanelNavigator.validatedSelection(currentID: nil, itemIDs: ["a", "b"]) == "a")
    #expect(GlobalSessionPanelNavigator.validatedSelection(currentID: "a", itemIDs: []) == nil)
  }

  @Test("Cleanup suggestions include quiet merged worktrees")
  func cleanupSuggestionsIncludeQuietMergedWorktrees() {
    let worktreePath = "/tmp/agenthub-cleanup/feature-merged"
    let items = [
      cleanupItem(
        id: "merged",
        path: worktreePath,
        providerKind: .claude,
        status: .idle,
        linkedPullRequestNumber: 12,
        gitHubState: gitHubState(number: 12, state: .merged)
      ),
      cleanupItem(
        id: "no-pr-sibling",
        path: worktreePath,
        providerKind: .codex,
        status: .waitingForUser,
        gitHubState: nil
      ),
    ]

    let suggestions = GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: items)

    #expect(suggestions.count == 1)
    #expect(suggestions.first?.worktreePath == worktreePath)
    #expect(suggestions.first?.worktreeName == "feature-merged")
    #expect(suggestions.first?.sessionIDs == ["merged", "no-pr-sibling"])
    #expect(suggestions.first?.providerKinds == [.claude, .codex])
    #expect(suggestions.first?.mergedPullRequestNumbers == [12])
  }

  @Test("Cleanup suggestions require merged PR evidence")
  func cleanupSuggestionsRequireMergedPullRequestEvidence() {
    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "no-github", gitHubState: nil)
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "open", gitHubState: gitHubState(state: .open))
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "closed", gitHubState: gitHubState(state: .closed))
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "unknown", gitHubState: gitHubState(state: .unknown("UNKNOWN")))
    ]).isEmpty)
  }

  @Test("Cleanup suggestions block unsafe worktree state")
  func cleanupSuggestionsBlockUnsafeWorktreeState() {
    let worktreePath = "/tmp/agenthub-cleanup/feature-blocked"
    let safeMerged = cleanupItem(
      id: "merged",
      path: worktreePath,
      gitHubState: gitHubState(number: 88, state: .merged)
    )

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "active", path: worktreePath, isActive: true, gitHubState: gitHubState(state: .merged))
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      safeMerged,
      cleanupItem(id: "pending", path: worktreePath, isPending: true, status: nil, gitHubState: nil),
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "thinking", path: worktreePath, status: .thinking, gitHubState: gitHubState(state: .merged))
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(
        id: "approval",
        path: worktreePath,
        status: .awaitingApproval(tool: "Bash"),
        gitHubState: gitHubState(state: .merged)
      )
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "ci-pending", path: worktreePath, gitHubState: gitHubState(state: .merged, ciStatus: .pending))
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "ci-failure", path: worktreePath, gitHubState: gitHubState(state: .merged, ciStatus: .failure))
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      safeMerged,
      cleanupItem(id: "open-pr", path: worktreePath, gitHubState: gitHubState(number: 89, state: .open)),
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(
        id: "conflicting",
        path: worktreePath,
        gitHubState: gitHubState(state: .merged, mergeability: .conflicting)
      )
    ]).isEmpty)

    #expect(GlobalSessionCleanupSuggestionBuilder.makeSuggestions(items: [
      cleanupItem(id: "main-repo", isWorktree: false, gitHubState: gitHubState(state: .merged))
    ]).isEmpty)
  }

  private func item(
    id: String,
    seconds: TimeInterval,
    status: SessionStatus?,
    ciStatus: CIStatus? = nil
  ) -> (id: String, seconds: TimeInterval, status: SessionStatus?, ciStatus: CIStatus?) {
    (id, seconds, status, ciStatus)
  }

  private func cleanupItem(
    id: String,
    path: String = "/tmp/agenthub-cleanup/feature",
    providerKind: SessionProviderKind = .claude,
    isWorktree: Bool = true,
    isActive: Bool = false,
    isPending: Bool = false,
    status: SessionStatus? = .idle,
    linkedPullRequestNumber: Int? = nil,
    gitHubState: GlobalSessionControlPanelGitHubState? = nil
  ) -> GlobalSessionControlPanelItem {
    GlobalSessionControlPanelItem(
      id: id,
      session: CLISession(
        id: id,
        projectPath: path,
        branchName: "feature",
        isWorktree: isWorktree,
        lastActivityAt: Date(timeIntervalSince1970: 1_000),
        isActive: isActive
      ),
      providerKind: providerKind,
      timestamp: Date(timeIntervalSince1970: 1_000),
      isPending: isPending,
      status: status,
      linkedPullRequestNumber: linkedPullRequestNumber,
      customName: nil,
      gitHubState: gitHubState
    )
  }

  private func gitHubState(
    number: Int = 12,
    state: GitHubPullRequestState,
    ciStatus: CIStatus = .success,
    mergeability: GitHubMergeability? = nil
  ) -> GlobalSessionControlPanelGitHubState {
    GlobalSessionControlPanelGitHubState(
      hasPullRequest: true,
      ciStatus: ciStatus,
      pullRequestNumber: number,
      pullRequestState: state,
      pullRequestMergeability: mergeability
    )
  }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "GlobalSessionControlPanelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
