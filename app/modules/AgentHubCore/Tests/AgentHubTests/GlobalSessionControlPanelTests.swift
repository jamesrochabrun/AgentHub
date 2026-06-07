import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

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

  private func item(
    id: String,
    seconds: TimeInterval,
    status: SessionStatus?,
    ciStatus: CIStatus? = nil
  ) -> (id: String, seconds: TimeInterval, status: SessionStatus?, ciStatus: CIStatus?) {
    (id, seconds, status, ciStatus)
  }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "GlobalSessionControlPanelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
