import AppKit
import Canvas
import Combine
import Foundation
import Testing

@testable import AgentHubCore
@testable import AgentHubTerminalUI

private actor AuxiliaryShellStubMonitorService: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private actor AuxiliaryShellStubFileWatcher: SessionFileWatcherProtocol {
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

@MainActor
private func makeAuxiliaryShellViewModel(
  terminalSurfaceFactory: any EmbeddedTerminalSurfaceFactory = DefaultEmbeddedTerminalSurfaceFactory(),
  terminalBackend: EmbeddedTerminalBackend = .storedPreference,
  terminalWorkspaceStore: (any TerminalWorkspaceStoreProtocol)? = nil
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: AuxiliaryShellStubMonitorService(),
    fileWatcher: AuxiliaryShellStubFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService(),
    terminalSurfaceFactory: terminalSurfaceFactory,
    terminalBackend: terminalBackend,
    terminalWorkspaceStore: terminalWorkspaceStore
  )
}

@MainActor
private final class TestTerminalSurface: NSView, EmbeddedTerminalSurface {
  var view: NSView { self }
  var currentProcessPID: Int32?
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)?
  var onOpenFile: ((String, Int?) -> Void)?
  private(set) var configuredProjectPath: String?
  private(set) var configuredShellPath: String?
  private(set) var configuredInitialInputText: String?
  private(set) var typedTexts: [String] = []
  private(set) var initialTypedTexts: [String] = []
  private(set) var restoredWorkspaceSnapshot: TerminalWorkspaceSnapshot?
  var workspaceSnapshotToCapture: TerminalWorkspaceSnapshot?
  private(set) var configureCallCount = 0
  private(set) var terminateCallCount = 0

  func updateContext(terminalSessionKey: String?) {}

  func configure(
    launch: Result<EmbeddedTerminalLaunch, EmbeddedTerminalLaunchError>,
    projectPath: String,
    initialInputText: String?,
    isDark: Bool
  ) {
    configuredProjectPath = projectPath
    configuredInitialInputText = initialInputText
    configureCallCount += 1
  }

  func configureShell(launch: EmbeddedTerminalLaunch, projectPath: String, isDark: Bool) {
    configuredProjectPath = projectPath
    configureCallCount += 1
  }

  func restart(launch: Result<EmbeddedTerminalLaunch, EmbeddedTerminalLaunchError>, projectPath: String) {}

  func terminateProcess() {
    terminateCallCount += 1
  }

  func resetPromptDeliveryFlag() {}
  func sendPromptIfNeeded(_ prompt: String) {}
  func submitPromptImmediately(_ prompt: String) -> Bool { true }
  func typeText(_ text: String) {
    typedTexts.append(text)
  }
  func typeInitialTextIfNeeded(_ text: String) {
    initialTypedTexts.append(text)
  }
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: TerminalAppearanceTheme?) {}
  func focus() {}
  func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot? {
    workspaceSnapshotToCapture
  }
  func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) {
    restoredWorkspaceSnapshot = snapshot
  }
}

private final class RecordingTerminalWorkspaceStore: TerminalWorkspaceStoreProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var snapshots: [String: TerminalWorkspaceSnapshot]
  private var savedSnapshotsByKey: [String: TerminalWorkspaceSnapshot] = [:]

  init(snapshots: [String: TerminalWorkspaceSnapshot] = [:]) {
    self.snapshots = snapshots
  }

  func loadTerminalWorkspace(
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) -> TerminalWorkspaceSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return snapshots[key(provider: provider, sessionId: sessionId, backend: backend)]
  }

  func saveTerminalWorkspace(
    _ snapshot: TerminalWorkspaceSnapshot,
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) async throws {
    lock.lock()
    defer { lock.unlock() }
    let key = key(provider: provider, sessionId: sessionId, backend: backend)
    snapshots[key] = snapshot
    savedSnapshotsByKey[key] = snapshot
  }

  func deleteTerminalWorkspace(
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) async throws {
    lock.lock()
    defer { lock.unlock() }
    snapshots.removeValue(forKey: key(provider: provider, sessionId: sessionId, backend: backend))
  }

  func savedSnapshot(
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) -> TerminalWorkspaceSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return savedSnapshotsByKey[key(provider: provider, sessionId: sessionId, backend: backend)]
  }

  private func key(
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) -> String {
    "\(provider.rawValue)|\(sessionId)|\(backend.rawValue)"
  }
}

@MainActor
private final class RecordingTerminalSurfaceFactory: EmbeddedTerminalSurfaceFactory {
  private let surfaces: [TestTerminalSurface]
  private var nextSurfaceIndex = 0
  private(set) var requestedBackends: [EmbeddedTerminalBackend] = []

  init(surfaces: [TestTerminalSurface]) {
    self.surfaces = surfaces
  }

  func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    requestedBackends.append(backend)
    let surface = surfaces[nextSurfaceIndex]
    nextSurfaceIndex += 1
    return surface
  }
}

@Suite("Auxiliary shell terminal management", .serialized)
struct AuxiliaryShellTerminalManagementTests {

  @Test("Typing to an active terminal sends text immediately")
  @MainActor
  func typeToTerminalUsesActiveTerminal() {
    let viewModel = makeAuxiliaryShellViewModel()
    let terminal = TestTerminalSurface()
    viewModel.activeTerminals["session-123"] = terminal

    viewModel.typeToTerminal(forKey: "session-123", text: "/review https://github.com/example/repo/pull/1 ")

    #expect(terminal.typedTexts == ["/review https://github.com/example/repo/pull/1 "])
    #expect(viewModel.pendingTerminalInputTexts["session-123"] == nil)
  }

  @Test("Typing to a missing terminal queues text for creation")
  @MainActor
  func typeToTerminalQueuesUntilTerminalCreation() {
    let terminal = TestTerminalSurface()
    let factory = RecordingTerminalSurfaceFactory(surfaces: [terminal])
    let viewModel = makeAuxiliaryShellViewModel(terminalSurfaceFactory: factory, terminalBackend: .swiftTerm)
    let command = "fix https://github.com/example/repo/issues/7 "

    viewModel.typeToTerminal(forKey: "session-123", text: command)

    #expect(viewModel.pendingTerminalInputTexts["session-123"] == command)

    _ = viewModel.getOrCreateTerminal(
      forKey: "session-123",
      sessionId: "session-123",
      projectPath: "/tmp/repo",
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      initialPrompt: nil,
      initialInputText: nil,
      isDark: true
    )

    #expect(terminal.configuredInitialInputText == command)
    #expect(viewModel.pendingTerminalInputTexts["session-123"] == nil)
  }

  @Test("Transfers auxiliary shell terminal from pending key to resolved session ID")
  @MainActor
  func transferAuxiliaryShellTerminal() {
    let viewModel = makeAuxiliaryShellViewModel()
    let pendingID = UUID()
    let pendingKey = "pending-\(pendingID.uuidString)"
    let terminal = TerminalContainerView()
    viewModel.auxiliaryShellTerminals[pendingKey] = terminal

    viewModel.transferAuxiliaryShellTerminal(fromPendingId: pendingID, toSessionId: "session-123")

    #expect(viewModel.auxiliaryShellTerminals[pendingKey] == nil)
    #expect(viewModel.auxiliaryShellTerminals["session-123"]?.view === terminal)
  }

  @Test("Resolving pending session transfers queued web preview context")
  @MainActor
  func transferTerminalMovesQueuedWebPreviewContext() {
    let viewModel = makeAuxiliaryShellViewModel()
    let pendingID = UUID()
    let pendingKey = "pending-\(pendingID.uuidString)"
    let element = makeQueuedElement()

    viewModel.queueWebPreviewUpdate(
      element,
      instruction: "Make this button larger",
      for: pendingKey
    )

    viewModel.transferTerminal(fromPendingId: pendingID, toSessionId: "session-123")

    #expect(viewModel.queuedWebPreviewContextStore.count(for: pendingKey) == 0)
    #expect(viewModel.queuedWebPreviewContextStore.count(for: "session-123") == 1)
    #expect(viewModel.queuedWebPreviewContextStore.queue(for: "session-123").items.first?.detail == "Make this button larger")
  }

  @Test("Canceling pending session removes auxiliary shell terminal")
  @MainActor
  func cancelPendingSessionRemovesAuxiliaryShell() {
    let viewModel = makeAuxiliaryShellViewModel()
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "feature", path: "/tmp/feature", isWorktree: true)
    )
    let pendingKey = "pending-\(pending.id.uuidString)"
    viewModel.pendingHubSessions = [pending]
    viewModel.auxiliaryShellTerminals[pendingKey] = TerminalContainerView()

    viewModel.cancelPendingSession(pending)

    #expect(viewModel.pendingHubSessions.isEmpty)
    #expect(viewModel.auxiliaryShellTerminals[pendingKey] == nil)
  }

  @Test("Managed terminal entries include auxiliary shells")
  @MainActor
  func managedTerminalEntriesIncludeAuxiliaryShells() {
    let viewModel = makeAuxiliaryShellViewModel()
    viewModel.activeTerminals["session-123"] = TerminalContainerView()
    viewModel.auxiliaryShellTerminals["session-123"] = TerminalContainerView()

    let keys = viewModel.managedTerminalEntries.map(\.key)

    #expect(keys.contains("session-123"))
    #expect(keys.contains("shell:session-123"))
    #expect(keys.count == 2)
  }

  @Test("Stopping monitoring removes and terminates both terminal surfaces for the session")
  @MainActor
  func stopMonitoringRemovesAndTerminatesSessionTerminals() {
    let viewModel = makeAuxiliaryShellViewModel()
    let session = CLISession(
      id: "session-123",
      projectPath: "/tmp/project",
      branchName: "main"
    )
    let agentTerminal = TerminalContainerView()
    let shellTerminal = TerminalContainerView()

    viewModel.startMonitoring(session: session)
    viewModel.activeTerminals[session.id] = agentTerminal
    viewModel.auxiliaryShellTerminals[session.id] = shellTerminal

    viewModel.stopMonitoring(sessionId: session.id)

    #expect(!viewModel.isMonitoring(sessionId: session.id))
    #expect(viewModel.activeTerminals[session.id] == nil)
    #expect(viewModel.auxiliaryShellTerminals[session.id] == nil)
    #expect(agentTerminal.terminateProcessCallCount == 1)
    #expect(shellTerminal.terminateProcessCallCount == 1)
  }

  @Test("View model creates terminals through injected surface factory")
  @MainActor
  func createsTerminalThroughInjectedFactory() {
    let surface = TestTerminalSurface()
    let factory = RecordingTerminalSurfaceFactory(surfaces: [surface])
    let viewModel = makeAuxiliaryShellViewModel(
      terminalSurfaceFactory: factory,
      terminalBackend: .regular
    )

    let terminal = viewModel.getOrCreateTerminal(
      forKey: "session-123",
      sessionId: "session-123",
      projectPath: "/tmp/project",
      initialPrompt: nil
    )

    #expect(terminal.view === surface)
    #expect(surface.configuredProjectPath == "/tmp/project")
    #expect(factory.requestedBackends == [.regular])
  }

  @Test("Changing terminal backend preference does not recreate cached terminal surfaces")
  @MainActor
  func changingTerminalBackendPreferenceRequiresRestart() {
    let oldBackend = UserDefaults.standard.object(forKey: AgentHubDefaults.terminalBackend)
    defer {
      if let oldBackend {
        UserDefaults.standard.set(oldBackend, forKey: AgentHubDefaults.terminalBackend)
      } else {
        UserDefaults.standard.removeObject(forKey: AgentHubDefaults.terminalBackend)
      }
    }

    UserDefaults.standard.set(EmbeddedTerminalBackend.ghostty.rawValue, forKey: AgentHubDefaults.terminalBackend)
    let firstSurface = TestTerminalSurface()
    let secondSurface = TestTerminalSurface()
    let factory = RecordingTerminalSurfaceFactory(surfaces: [firstSurface, secondSurface])
    let viewModel = makeAuxiliaryShellViewModel(
      terminalSurfaceFactory: factory,
      terminalBackend: .ghostty
    )

    _ = viewModel.getOrCreateTerminal(
      forKey: "session-123",
      sessionId: "session-123",
      projectPath: "/tmp/project",
      initialPrompt: nil
    )

    UserDefaults.standard.set(EmbeddedTerminalBackend.regular.rawValue, forKey: AgentHubDefaults.terminalBackend)
    _ = viewModel.getOrCreateTerminal(
      forKey: "session-456",
      sessionId: "session-456",
      projectPath: "/tmp/another-project",
      initialPrompt: nil
    )

    #expect(firstSurface.terminateCallCount == 0)
    #expect(secondSurface.configuredProjectPath == "/tmp/another-project")
    #expect(viewModel.activeTerminals["session-123"]?.view === firstSurface)
    #expect(viewModel.activeTerminals["session-456"]?.view === secondSurface)
    #expect(factory.requestedBackends == [.ghostty, .ghostty])
  }

  @Test("Restores persisted workspace when creating a real session terminal")
  @MainActor
  func restoresPersistedWorkspaceForRealSessionTerminal() {
    let snapshot = makeWorkspaceSnapshot()
    let store = RecordingTerminalWorkspaceStore(snapshots: [
      "Claude|session-123|\(EmbeddedTerminalBackend.ghostty.rawValue)": snapshot
    ])
    let surface = TestTerminalSurface()
    let factory = RecordingTerminalSurfaceFactory(surfaces: [surface])
    let viewModel = makeAuxiliaryShellViewModel(
      terminalSurfaceFactory: factory,
      terminalBackend: .ghostty,
      terminalWorkspaceStore: store
    )

    _ = viewModel.getOrCreateTerminal(
      forKey: "session-123",
      sessionId: "session-123",
      projectPath: "/tmp/project",
      initialPrompt: nil
    )

    #expect(surface.restoredWorkspaceSnapshot == snapshot)
  }

  @Test("Restores persisted workspace for regular backend")
  @MainActor
  func restoresPersistedWorkspaceForRegularBackend() {
    let snapshot = makeWorkspaceSnapshot()
    let store = RecordingTerminalWorkspaceStore(snapshots: [
      "Claude|session-123|\(EmbeddedTerminalBackend.regular.rawValue)": snapshot
    ])
    let surface = TestTerminalSurface()
    let factory = RecordingTerminalSurfaceFactory(surfaces: [surface])
    let viewModel = makeAuxiliaryShellViewModel(
      terminalSurfaceFactory: factory,
      terminalBackend: .regular,
      terminalWorkspaceStore: store
    )

    _ = viewModel.getOrCreateTerminal(
      forKey: "session-123",
      sessionId: "session-123",
      projectPath: "/tmp/project",
      initialPrompt: nil
    )

    #expect(surface.restoredWorkspaceSnapshot == snapshot)
  }

  @Test("Saves terminal workspace changes through injected store")
  @MainActor
  func savesTerminalWorkspaceChanges() async throws {
    let snapshot = makeWorkspaceSnapshot(activePanelIndex: 1)
    let store = RecordingTerminalWorkspaceStore()
    let surface = TestTerminalSurface()
    let factory = RecordingTerminalSurfaceFactory(surfaces: [surface])
    let viewModel = makeAuxiliaryShellViewModel(
      terminalSurfaceFactory: factory,
      terminalBackend: .ghostty,
      terminalWorkspaceStore: store
    )

    _ = viewModel.getOrCreateTerminal(
      forKey: "session-123",
      sessionId: "session-123",
      projectPath: "/tmp/project",
      initialPrompt: nil
    )
    surface.onWorkspaceChanged?(snapshot)

    try await Task.sleep(for: .milliseconds(350))

    #expect(store.savedSnapshot(provider: .claude, sessionId: "session-123", backend: .ghostty) == snapshot)
  }

  @Test("Saves regular terminal workspace changes through injected store")
  @MainActor
  func savesRegularTerminalWorkspaceChanges() async throws {
    let snapshot = makeWorkspaceSnapshot(activePanelIndex: 1)
    let store = RecordingTerminalWorkspaceStore()
    let surface = TestTerminalSurface()
    let factory = RecordingTerminalSurfaceFactory(surfaces: [surface])
    let viewModel = makeAuxiliaryShellViewModel(
      terminalSurfaceFactory: factory,
      terminalBackend: .regular,
      terminalWorkspaceStore: store
    )

    _ = viewModel.getOrCreateTerminal(
      forKey: "session-123",
      sessionId: "session-123",
      projectPath: "/tmp/project",
      initialPrompt: nil
    )
    surface.onWorkspaceChanged?(snapshot)

    try await Task.sleep(for: .milliseconds(350))

    #expect(store.savedSnapshot(provider: .claude, sessionId: "session-123", backend: .regular) == snapshot)
  }

  @Test("Pending terminal workspace is saved when session resolves")
  @MainActor
  func pendingTerminalWorkspaceSavesAfterTransfer() async throws {
    let snapshot = makeWorkspaceSnapshot(activePanelIndex: 1)
    let store = RecordingTerminalWorkspaceStore()
    let surface = TestTerminalSurface()
    surface.workspaceSnapshotToCapture = snapshot
    let pendingID = UUID()
    let pendingKey = "pending-\(pendingID.uuidString)"
    let viewModel = makeAuxiliaryShellViewModel(
      terminalBackend: .ghostty,
      terminalWorkspaceStore: store
    )
    viewModel.activeTerminals[pendingKey] = surface

    viewModel.transferTerminal(fromPendingId: pendingID, toSessionId: "session-123")

    try await Task.sleep(for: .milliseconds(350))

    #expect(store.savedSnapshot(provider: .claude, sessionId: "session-123", backend: .ghostty) == snapshot)
  }
}

private func makeQueuedElement() -> ElementInspectorData {
  ElementInspectorData(
    tagName: "BUTTON",
    elementId: "",
    className: "",
    textContent: "",
    outerHTML: "<button>Launch</button>",
    cssSelector: ".hero button",
    computedStyles: [:],
    boundingRect: .zero
  )
}

private func makeWorkspaceSnapshot(activePanelIndex: Int = 0) -> TerminalWorkspaceSnapshot {
  TerminalWorkspaceSnapshot(
    panels: [
      TerminalWorkspacePanelSnapshot(
        role: .primary,
        tabs: [
          TerminalWorkspaceTabSnapshot(
            role: .agent,
            name: "Agent",
            title: "Claude",
            workingDirectory: "/tmp/project"
          ),
          TerminalWorkspaceTabSnapshot(
            role: .shell,
            name: "Shell",
            title: "zsh",
            workingDirectory: "/tmp/project"
          )
        ],
        activeTabIndex: 1
      ),
      TerminalWorkspacePanelSnapshot(
        role: .auxiliary,
        tabs: [
          TerminalWorkspaceTabSnapshot(
            role: .shell,
            name: "Shell",
            title: "zsh",
            workingDirectory: "/tmp/project"
          )
        ]
      )
    ],
    activePanelIndex: activePanelIndex
  )
}
