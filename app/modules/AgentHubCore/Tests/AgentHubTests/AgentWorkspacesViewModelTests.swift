import AppKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Agent workspaces view model")
struct AgentWorkspacesViewModelTests {
  @Test("Loading records does not mount terminals until selected")
  func lazyTerminalMount() async throws {
    let workspace = try makeWorkspace(id: "workspace-1")
    let store = WorkspaceStoreSpy(workspaces: [workspace])
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(store: store, surface: surface)

    await viewModel.load()

    #expect(viewModel.workspaces == [workspace])
    #expect(surface.configureShellCallCount == 0)

    let mounted = viewModel.terminalSurface(for: workspace.id, isDark: true)
    let expectedSnapshot = try workspace.decodedSnapshot()

    #expect(mounted != nil)
    #expect(surface.configureShellCallCount == 1)
    #expect(surface.restoredSnapshot == expectedSnapshot)
    #expect(surface.terminalSessionKey == "workspace-workspace-1")
  }

  @Test("Create, default names, rename, and close persist")
  func workspaceLifecycle() async throws {
    let store = WorkspaceStoreSpy()
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(store: store, surface: surface)

    let firstID = try #require(await viewModel.createWorkspace(projectPath: "/tmp/project"))
    let secondID = try #require(await viewModel.createWorkspace(projectPath: "/tmp/project"))
    let first = try #require(viewModel.workspace(id: firstID))
    let second = try #require(viewModel.workspace(id: secondID))
    #expect(viewModel.displayName(for: first) == "Workspace")
    #expect(viewModel.displayName(for: second) == "Workspace 2")

    await viewModel.renameWorkspace(id: secondID, name: "Build Lab")
    #expect(viewModel.workspace(id: secondID)?.customName == "Build Lab")

    _ = viewModel.terminalSurface(for: secondID, isDark: false)
    #expect(viewModel.requiresCloseConfirmation(id: secondID))
    await viewModel.closeWorkspace(id: secondID)

    #expect(surface.terminateCallCount == 1)
    #expect(viewModel.workspace(id: secondID) == nil)
    #expect(await store.deletedIDs() == [secondID])
  }

  @Test("Explicit agent launch attaches the detected session")
  func explicitAgentLaunch() async throws {
    let result = AccessorySessionDetectionResult(
      provider: .codex,
      sessionId: "codex-session",
      projectPath: "/tmp/project",
      branchName: "main",
      sessionFilePath: "/tmp/codex-session.jsonl"
    )
    let detection = WorkspaceDetectionServiceSpy(results: [.codex: result])
    let coordinator = WorkspaceSessionCoordinatorSpy()
    let store = WorkspaceStoreSpy()
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(
      store: store,
      surface: surface,
      coordinator: coordinator,
      detection: detection
    )
    let workspaceID = try #require(await viewModel.createWorkspace(projectPath: "/tmp/project"))
    _ = viewModel.terminalSurface(for: workspaceID, isDark: true)

    viewModel.launchSurface(
      workspaceID: workspaceID,
      kind: .agent(.codex),
      placement: .splitDown,
      isDark: true
    )
    try await Task.sleep(for: .milliseconds(80))

    #expect(surface.launches.count == 1)
    #expect(surface.launches.first?.kind == .agent(.codex))
    #expect(surface.launches.first?.placement == .splitDown)
    #expect(surface.launches.first?.configuration?.mode == .codex)
    #expect(surface.markedSessions == ["codex:codex-session"])
    #expect(viewModel.linksByWorkspaceID[workspaceID]?.first?.relationshipOrigin == .explicit)
    #expect(coordinator.monitoredSessionIDs == ["codex-session"])
  }

  @Test("A unique shell passively attaches a manually started agent")
  func passiveDetection() async throws {
    let result = AccessorySessionDetectionResult(
      provider: .claude,
      sessionId: "claude-session",
      projectPath: "/tmp/project",
      branchName: "main",
      sessionFilePath: "/tmp/claude-session.jsonl"
    )
    let detection = WorkspaceDetectionServiceSpy(results: [.claude: result])
    let coordinator = WorkspaceSessionCoordinatorSpy()
    let workspace = try makeWorkspace(id: "workspace-1")
    let store = WorkspaceStoreSpy(workspaces: [workspace])
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(
      store: store,
      surface: surface,
      coordinator: coordinator,
      detection: detection
    )
    await viewModel.load()

    _ = viewModel.terminalSurface(for: workspace.id, isDark: true)
    try await Task.sleep(for: .milliseconds(80))

    #expect(viewModel.linksByWorkspaceID[workspace.id]?.first?.relationshipOrigin == .detected)
    #expect(coordinator.monitoredSessionIDs == ["claude-session"])
  }

  @Test("Same-directory shell ambiguity does not guess a pane")
  func ambiguousPassiveDetection() async throws {
    let snapshot = TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp/project")]
        ),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp/project")]
        )
      ]
    )
    let workspace = try AgentWorkspaceRecord(
      id: "workspace-1",
      projectPath: "/tmp/project",
      snapshot: snapshot
    )
    let detection = WorkspaceDetectionServiceSpy(results: [:])
    let store = WorkspaceStoreSpy(workspaces: [workspace])
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(store: store, surface: surface, detection: detection)
    await viewModel.load()

    _ = viewModel.terminalSurface(for: workspace.id, isDark: true)
    try await Task.sleep(for: .milliseconds(50))

    #expect(detection.detectCallCount == 0)
    #expect(viewModel.linksByWorkspaceID[workspace.id]?.isEmpty == true)
  }
}

@MainActor
private func makeViewModel(
  store: WorkspaceStoreSpy,
  surface: WorkspaceTerminalSurfaceSpy,
  coordinator: WorkspaceSessionCoordinatorSpy? = nil,
  detection: WorkspaceDetectionServiceSpy? = nil
) -> AgentWorkspacesViewModel {
  AgentWorkspacesViewModel(
    store: store,
    metadataStore: nil,
    terminalSurfaceFactory: WorkspaceTerminalSurfaceFactorySpy(surface: surface),
    sessionCoordinator: coordinator ?? WorkspaceSessionCoordinatorSpy(),
    detectionService: detection ?? WorkspaceDetectionServiceSpy(results: [:]),
    detectionPollInterval: .milliseconds(10)
  )
}

private func makeWorkspace(id: String) throws -> AgentWorkspaceRecord {
  try AgentWorkspaceRecord(
    id: id,
    projectPath: "/tmp/project",
    snapshot: TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp/project")]
        )
      ]
    )
  )
}

private actor WorkspaceStoreSpy: AgentWorkspaceStoreProtocol {
  private var workspaces: [AgentWorkspaceRecord]
  private var links: [AgentWorkspaceSessionLink]
  private var deletedWorkspaceIDs: [String] = []

  init(
    workspaces: [AgentWorkspaceRecord] = [],
    links: [AgentWorkspaceSessionLink] = []
  ) {
    self.workspaces = workspaces
    self.links = links
  }

  func loadAgentWorkspaces() async throws -> [AgentWorkspaceRecord] { workspaces }
  func loadAgentWorkspaceSessionLinks() async throws -> [AgentWorkspaceSessionLink] { links }

  func saveAgentWorkspace(
    _ workspace: AgentWorkspaceRecord,
    links: [AgentWorkspaceSessionLink]
  ) async throws {
    workspaces.removeAll { $0.id == workspace.id }
    workspaces.append(workspace)
    self.links.removeAll { $0.workspaceId == workspace.id }
    self.links.append(contentsOf: links)
  }

  func deleteAgentWorkspace(id: String) async throws {
    workspaces.removeAll { $0.id == id }
    links.removeAll { $0.workspaceId == id }
    deletedWorkspaceIDs.append(id)
  }

  func deletedIDs() -> [String] { deletedWorkspaceIDs }
}

@MainActor
private final class WorkspaceSessionCoordinatorSpy: AgentWorkspaceSessionCoordinating {
  var monitoredSessionIDs: [String] = []

  func cliConfiguration(for provider: SessionProviderKind) -> CLICommandConfiguration {
    provider == .claude ? .claudeDefault : .codexDefault
  }

  func monitorDetectedSession(_ result: AccessorySessionDetectionResult) {
    monitoredSessionIDs.append(result.sessionId)
  }

  func activity(for links: [AgentWorkspaceSessionLink]) -> AgentWorkspaceActivity {
    links.isEmpty ? .idle : .working
  }
}

private final class WorkspaceDetectionServiceSpy: AccessorySessionDetectionServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private let results: [SessionProviderKind: AccessorySessionDetectionResult]
  private var deliveredProviders: Set<SessionProviderKind> = []
  private(set) var detectCallCount = 0

  init(results: [SessionProviderKind: AccessorySessionDetectionResult]) {
    self.results = results
  }

  func makeBaseline(
    provider: SessionProviderKind,
    projectPath: String,
    startedAt: Date
  ) -> AccessorySessionDetectionBaseline {
    AccessorySessionDetectionBaseline(
      provider: provider,
      projectPath: projectPath,
      startedAt: startedAt,
      knownSessionFiles: []
    )
  }

  func detectNewSession(
    provider: SessionProviderKind,
    projectPath: String,
    startedAt: Date,
    baseline: AccessorySessionDetectionBaseline
  ) -> AccessorySessionDetectionResult? {
    lock.lock()
    detectCallCount += 1
    let wasInserted = deliveredProviders.insert(provider).inserted
    lock.unlock()
    return wasInserted ? results[provider] : nil
  }
}

@MainActor
private final class WorkspaceTerminalSurfaceFactorySpy: EmbeddedTerminalSurfaceFactory {
  let surface: WorkspaceTerminalSurfaceSpy

  init(surface: WorkspaceTerminalSurfaceSpy) {
    self.surface = surface
  }

  func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    surface
  }
}

@MainActor
private final class WorkspaceTerminalSurfaceSpy: NSView, EmbeddedTerminalSurface {
  struct Launch {
    let kind: WorkspaceTerminalLaunchKind
    let placement: WorkspaceSurfacePlacement
    let configuration: CLICommandConfiguration?
  }

  var view: NSView { self }
  var currentProcessPID: Int32?
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)?
  var workspaceCLIConfigurationProvider: ((SessionProviderKind) -> CLICommandConfiguration)?
  private(set) var configureShellCallCount = 0
  private(set) var terminateCallCount = 0
  private(set) var terminalSessionKey: String?
  private(set) var restoredSnapshot: TerminalWorkspaceSnapshot?
  private(set) var launches: [Launch] = []
  private(set) var markedSessions: [String] = []

  func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {
    self.terminalSessionKey = terminalSessionKey
  }

  func configure(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?,
    initialInputText: String?,
    isDark: Bool,
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool,
    worktreeName: String?,
    metadataStore: SessionMetadataStore?
  ) {}

  func configureShell(projectPath: String, isDark: Bool, shellPath: String?) {
    configureShellCallCount += 1
  }

  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration) {}
  func terminateProcess() { terminateCallCount += 1 }
  func resetPromptDeliveryFlag() {}
  func sendPromptIfNeeded(_ prompt: String) {}
  func submitPromptImmediately(_ prompt: String) -> Bool { false }
  func typeText(_ text: String) {}
  func typeInitialTextIfNeeded(_ text: String) {}
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {}
  func focus() {}
  func activeWorkingDirectory() -> String? { "/tmp/project" }

  func openWorkspaceSurface(
    kind: WorkspaceTerminalLaunchKind,
    placement: WorkspaceSurfacePlacement,
    cliConfiguration: CLICommandConfiguration?,
    projectPath: String,
    metadataStore: SessionMetadataStore?
  ) -> WorkspaceSurfaceLaunchContext? {
    launches.append(Launch(kind: kind, placement: placement, configuration: cliConfiguration))
    guard var snapshot = restoredSnapshot else { return nil }
    let role: TerminalWorkspaceTabRole = if case .agent = kind { .agent } else { .shell }
    let tab = TerminalWorkspaceTabSnapshot(role: role, workingDirectory: projectPath)
    switch placement {
    case .tab:
      snapshot.panels[0].tabs.append(tab)
    case .splitRight, .splitDown:
      snapshot.panels.append(TerminalWorkspacePanelSnapshot(role: .auxiliary, tabs: [tab]))
    }
    restoredSnapshot = snapshot
    onWorkspaceChanged?(snapshot)
    let provider: SessionProviderKind? = if case .agent(let provider) = kind { provider } else { nil }
    return WorkspaceSurfaceLaunchContext(provider: provider, projectPath: projectPath, startedAt: .now)
  }

  func markAccessorySession(
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    origin: SessionRelationshipOrigin
  ) -> Bool {
    guard var snapshot = restoredSnapshot else { return false }
    for panelIndex in snapshot.panels.indices {
      for tabIndex in snapshot.panels[panelIndex].tabs.indices {
        guard snapshot.panels[panelIndex].tabs[tabIndex].linkedSession == nil,
              snapshot.panels[panelIndex].tabs[tabIndex].workingDirectory == projectPath else {
          continue
        }
        snapshot.panels[panelIndex].tabs[tabIndex].role = .agent
        snapshot.panels[panelIndex].tabs[tabIndex].linkedSession = TerminalWorkspaceLinkedSessionSnapshot(
          provider: provider,
          sessionId: sessionId
        )
        restoredSnapshot = snapshot
        markedSessions.append("\(provider.rawValue.lowercased()):\(sessionId)")
        onWorkspaceChanged?(snapshot)
        return true
      }
    }
    return false
  }

  func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot? { restoredSnapshot }
  func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) { restoredSnapshot = snapshot }
}
