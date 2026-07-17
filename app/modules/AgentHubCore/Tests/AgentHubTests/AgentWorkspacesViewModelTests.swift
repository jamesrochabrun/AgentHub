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

  @Test("Loading linked sessions reconciles normal monitoring without mounting terminals")
  func loadReconcilesPersistedSessionsLazily() async throws {
    let snapshot = TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp/project")]
        ),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .agent,
              workingDirectory: "/tmp/project/feature",
              linkedSession: TerminalWorkspaceLinkedSessionSnapshot(
                provider: .codex,
                sessionId: "codex-session"
              )
            )
          ]
        )
      ]
    )
    let workspace = try AgentWorkspaceRecord(
      id: "workspace-1",
      projectPath: "/tmp/project",
      snapshot: snapshot
    )
    let store = WorkspaceStoreSpy(
      workspaces: [workspace],
      links: [
        AgentWorkspaceSessionLink(
          workspaceId: workspace.id,
          provider: .codex,
          sessionId: "codex-session",
          origin: .explicit
        )
      ]
    )
    let coordinator = WorkspaceSessionCoordinatorSpy()
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(
      store: store,
      surface: surface,
      coordinator: coordinator
    )

    await viewModel.load()

    #expect(coordinator.restoredReferences == [
      AgentWorkspaceSessionReference(
        provider: .codex,
        sessionId: "codex-session",
        projectPath: "/tmp/project/feature"
      )
    ])
    #expect(surface.configureShellCallCount == 0)
  }

  @Test("Session ownership lookup resolves the linking workspace")
  func sessionOwnershipLookup() async throws {
    let workspace = try makeWorkspace(id: "workspace-1")
    let store = WorkspaceStoreSpy(
      workspaces: [workspace],
      links: [
        AgentWorkspaceSessionLink(
          workspaceId: workspace.id,
          provider: .claude,
          sessionId: "claude-session",
          origin: .detected
        )
      ]
    )
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(store: store, surface: surface)

    await viewModel.load()

    #expect(viewModel.workspaceID(owningSession: "claude-session", provider: .claude) == workspace.id)
    #expect(viewModel.workspaceID(owningSession: "claude-session", provider: .codex) == nil)
    #expect(viewModel.workspaceID(owningSession: "other-session", provider: .claude) == nil)
  }

  @Test("Focusing an owned session mounts the workspace surface and routes focus to its pane")
  func focusOwnedSessionRoutesToSurface() async throws {
    let workspace = try makeWorkspace(id: "workspace-1")
    let store = WorkspaceStoreSpy(
      workspaces: [workspace],
      links: [
        AgentWorkspaceSessionLink(
          workspaceId: workspace.id,
          provider: .claude,
          sessionId: "claude-session",
          origin: .detected
        )
      ]
    )
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(store: store, surface: surface)

    await viewModel.load()

    let focusedWorkspaceID = viewModel.focusWorkspaceSession(
      provider: .claude,
      sessionId: "claude-session",
      isDark: true
    )

    #expect(focusedWorkspaceID == workspace.id)
    #expect(surface.configureShellCallCount == 1)
    #expect(surface.focusedSessions == ["claude:claude-session"])

    let unownedWorkspaceID = viewModel.focusWorkspaceSession(
      provider: .codex,
      sessionId: "claude-session",
      isDark: true
    )

    #expect(unownedWorkspaceID == nil)
    #expect(surface.focusedSessions == ["claude:claude-session"])
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

  @Test(
    "Explicit agent tabs and splits attach and persist the detected session",
    arguments: [WorkspaceSurfacePlacement.tab, .splitDown]
  )
  func explicitAgentLaunch(placement: WorkspaceSurfacePlacement) async throws {
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
      placement: placement,
      isDark: true
    )
    try await Task.sleep(for: .milliseconds(80))

    #expect(surface.launches.count == 1)
    #expect(surface.launches.first?.kind == .agent(.codex))
    #expect(surface.launches.first?.placement == placement)
    #expect(surface.launches.first?.configuration?.mode == .codex)
    #expect(surface.markedSessions == ["codex:codex-session"])
    #expect(viewModel.linksByWorkspaceID[workspaceID]?.first?.relationshipOrigin == .explicit)
    #expect(coordinator.monitoredSessionIDs == ["codex-session"])

    let savedWorkspace = try #require(await store.workspace(id: workspaceID))
    let savedSnapshot = try savedWorkspace.decodedSnapshot()
    let linkedSessions = savedSnapshot.panels.flatMap(\.tabs).compactMap(\.linkedSession)
    #expect(linkedSessions.map(\.sessionId) == ["codex-session"])
    #expect(savedSnapshot.panels.count == (placement == .tab ? 1 : 2))
    #expect(await store.links(for: workspaceID).map(\.sessionId) == ["codex-session"])
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
    let workspace = try makeWorkspace(
      id: "workspace-1",
      title: "✳ Claude Code"
    )
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

  @Test("Same-directory Claude and Codex shells attach to their exact surfaces")
  func sameDirectoryPassiveDetectionUsesSurfaceIdentity() async throws {
    let snapshot = TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .shell,
              title: "✳ Claude Code",
              workingDirectory: "/tmp/project"
            )
          ]
        ),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .shell,
              title: "Codex",
              workingDirectory: "/tmp/project"
            )
          ]
        )
      ]
    )
    let workspace = try AgentWorkspaceRecord(
      id: "workspace-1",
      projectPath: "/tmp/project",
      snapshot: snapshot
    )
    let detection = WorkspaceDetectionServiceSpy(
      results: [
        .claude: AccessorySessionDetectionResult(
          provider: .claude,
          sessionId: "claude-session",
          projectPath: "/tmp/project",
          branchName: "main",
          sessionFilePath: "/tmp/claude-session.jsonl"
        ),
        .codex: AccessorySessionDetectionResult(
          provider: .codex,
          sessionId: "codex-session",
          projectPath: "/tmp/project",
          branchName: "main",
          sessionFilePath: "/tmp/codex-session.jsonl"
        )
      ]
    )
    let coordinator = WorkspaceSessionCoordinatorSpy()
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
    try await Task.sleep(for: .milliseconds(120))

    let savedWorkspace = try #require(await store.workspace(id: workspace.id))
    let savedTabs = try savedWorkspace.decodedSnapshot().panels.flatMap(\.tabs)
    #expect(savedTabs[0].linkedSession?.provider == .claude)
    #expect(savedTabs[0].linkedSession?.sessionId == "claude-session")
    #expect(savedTabs[1].linkedSession?.provider == .codex)
    #expect(savedTabs[1].linkedSession?.sessionId == "codex-session")
    #expect(Set(surface.markedContextIDs) == ["spy-0-0", "spy-1-0"])
    #expect(Set(coordinator.monitoredSessionIDs) == ["claude-session", "codex-session"])
    #expect(await store.links(for: workspace.id).count == 2)

    let relaunchedSurface = WorkspaceTerminalSurfaceSpy()
    let relaunchedCoordinator = WorkspaceSessionCoordinatorSpy()
    let relaunchedViewModel = makeViewModel(
      store: store,
      surface: relaunchedSurface,
      coordinator: relaunchedCoordinator
    )
    await relaunchedViewModel.load()
    _ = relaunchedViewModel.terminalSurface(for: workspace.id, isDark: true)

    let restoredIdentities = Set(relaunchedCoordinator.restoredReferences.map {
      "\($0.provider.rawValue):\($0.sessionId)"
    })
    #expect(restoredIdentities == ["Claude:claude-session", "Codex:codex-session"])
    let restoredTabs = try #require(relaunchedSurface.restoredSnapshot).panels.flatMap(\.tabs)
    #expect(restoredTabs.map(\.role) == [.agent, .agent])
    #expect(Set(restoredTabs.compactMap(\.linkedSession?.sessionId)) == [
      "claude-session",
      "codex-session"
    ])
  }

  @Test("One discovered session cannot attach to two same-provider surfaces")
  func duplicateDetectionDoesNotCrossLinkSurfaces() async throws {
    let snapshot = TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .shell,
              title: "Claude Code",
              workingDirectory: "/tmp/project"
            )
          ]
        ),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .shell,
              title: "Claude Code",
              workingDirectory: "/tmp/project"
            )
          ]
        )
      ]
    )
    let workspace = try AgentWorkspaceRecord(
      id: "workspace-1",
      projectPath: "/tmp/project",
      snapshot: snapshot
    )
    let result = AccessorySessionDetectionResult(
      provider: .claude,
      sessionId: "shared-session",
      projectPath: "/tmp/project",
      branchName: "main",
      sessionFilePath: "/tmp/shared-session.jsonl"
    )
    let detection = WorkspaceDetectionServiceSpy(
      results: [.claude: result],
      deliveriesPerProvider: 2
    )
    let store = WorkspaceStoreSpy(workspaces: [workspace])
    let surface = WorkspaceTerminalSurfaceSpy()
    let viewModel = makeViewModel(store: store, surface: surface, detection: detection)
    await viewModel.load()

    _ = viewModel.terminalSurface(for: workspace.id, isDark: true)
    try await Task.sleep(for: .milliseconds(120))

    let savedWorkspace = try #require(await store.workspace(id: workspace.id))
    let linkedTabs = try savedWorkspace.decodedSnapshot().panels
      .flatMap(\.tabs)
      .filter { $0.linkedSession != nil }
    #expect(linkedTabs.count == 1)
    #expect(await store.links(for: workspace.id).map(\.sessionId) == ["shared-session"])
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

private func makeWorkspace(id: String, title: String? = nil) throws -> AgentWorkspaceRecord {
  try AgentWorkspaceRecord(
    id: id,
    projectPath: "/tmp/project",
    snapshot: TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .shell,
              title: title,
              workingDirectory: "/tmp/project"
            )
          ]
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

  func workspace(id: String) -> AgentWorkspaceRecord? {
    workspaces.first { $0.id == id }
  }

  func links(for workspaceID: String) -> [AgentWorkspaceSessionLink] {
    links.filter { $0.workspaceId == workspaceID }
  }
}

@MainActor
private final class WorkspaceSessionCoordinatorSpy: AgentWorkspaceSessionCoordinating {
  var monitoredSessionIDs: [String] = []
  var restoredReferences: [AgentWorkspaceSessionReference] = []

  func cliConfiguration(for provider: SessionProviderKind) -> CLICommandConfiguration {
    provider == .claude ? .claudeDefault : .codexDefault
  }

  func monitorDetectedSession(_ result: AccessorySessionDetectionResult) async {
    monitoredSessionIDs.append(result.sessionId)
  }

  func restorePersistedSessions(_ references: [AgentWorkspaceSessionReference]) async {
    restoredReferences.append(contentsOf: references)
  }

  func activity(for links: [AgentWorkspaceSessionLink]) -> AgentWorkspaceActivity {
    links.isEmpty ? .idle : .working
  }
}

private final class WorkspaceDetectionServiceSpy: AccessorySessionDetectionServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private let results: [SessionProviderKind: AccessorySessionDetectionResult]
  private var remainingDeliveries: [SessionProviderKind: Int]
  private(set) var detectCallCount = 0

  init(
    results: [SessionProviderKind: AccessorySessionDetectionResult],
    deliveriesPerProvider: Int = 1
  ) {
    self.results = results
    remainingDeliveries = Dictionary(
      uniqueKeysWithValues: results.keys.map { ($0, deliveriesPerProvider) }
    )
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
    let remaining = remainingDeliveries[provider] ?? 0
    remainingDeliveries[provider] = max(0, remaining - 1)
    lock.unlock()
    return remaining > 0 ? results[provider] : nil
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
  private(set) var markedContextIDs: [String] = []
  private(set) var focusedSessions: [String] = []

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
    let provider: SessionProviderKind? = if case .agent(let provider) = kind { provider } else { nil }
    let tab = TerminalWorkspaceTabSnapshot(
      role: role,
      name: provider?.rawValue,
      workingDirectory: projectPath
    )
    let contextID: String
    switch placement {
    case .tab:
      snapshot.panels[0].tabs.append(tab)
      contextID = "spy-0-\(snapshot.panels[0].tabs.count - 1)"
    case .splitRight, .splitDown:
      snapshot.panels.append(TerminalWorkspacePanelSnapshot(role: .auxiliary, tabs: [tab]))
      contextID = "spy-\(snapshot.panels.count - 1)-0"
    }
    restoredSnapshot = snapshot
    onWorkspaceChanged?(snapshot)
    return WorkspaceSurfaceLaunchContext(
      provider: provider,
      projectPath: projectPath,
      startedAt: .now,
      detectionContextID: contextID
    )
  }

  func workspaceSessionDetectionContexts() -> [WorkspaceSessionDetectionContext] {
    guard let snapshot = restoredSnapshot else { return [] }
    return snapshot.panels.enumerated().flatMap { panelIndex, panel in
      panel.tabs.enumerated().compactMap { tabIndex, tab in
        guard tab.linkedSession == nil, let projectPath = tab.workingDirectory else { return nil }
        let label = [tab.name, tab.title]
          .compactMap { $0?.lowercased() }
          .joined(separator: " ")
        let provider: SessionProviderKind? = if label.contains("claude") {
          .claude
        } else if label.contains("codex") {
          .codex
        } else {
          nil
        }
        return WorkspaceSessionDetectionContext(
          id: "spy-\(panelIndex)-\(tabIndex)",
          provider: provider,
          projectPath: projectPath,
          foregroundProcessID: nil
        )
      }
    }
  }

  @discardableResult
  func focusWorkspaceSession(
    provider: SessionProviderKind,
    sessionId: String
  ) -> Bool {
    focusedSessions.append("\(provider.rawValue.lowercased()):\(sessionId)")
    return true
  }

  func markWorkspaceSession(
    contextID: String,
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    origin: SessionRelationshipOrigin
  ) -> Bool {
    guard var snapshot = restoredSnapshot else { return false }
    for panelIndex in snapshot.panels.indices {
      for tabIndex in snapshot.panels[panelIndex].tabs.indices
      where "spy-\(panelIndex)-\(tabIndex)" == contextID {
        guard snapshot.panels[panelIndex].tabs[tabIndex].linkedSession == nil else {
          return false
        }
        snapshot.panels[panelIndex].tabs[tabIndex].role = .agent
        snapshot.panels[panelIndex].tabs[tabIndex].name = provider.rawValue
        snapshot.panels[panelIndex].tabs[tabIndex].linkedSession =
          TerminalWorkspaceLinkedSessionSnapshot(provider: provider, sessionId: sessionId)
        restoredSnapshot = snapshot
        markedSessions.append("\(provider.rawValue.lowercased()):\(sessionId)")
        markedContextIDs.append(contextID)
        onWorkspaceChanged?(snapshot)
        return true
      }
    }
    return false
  }

  func markAccessorySession(
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    origin: SessionRelationshipOrigin
  ) -> Bool {
    guard var snapshot = restoredSnapshot else { return false }
    let candidates = snapshot.panels.indices.flatMap { panelIndex in
      snapshot.panels[panelIndex].tabs.indices.compactMap { tabIndex -> (Int, Int)? in
        let tab = snapshot.panels[panelIndex].tabs[tabIndex]
        guard tab.linkedSession == nil, tab.workingDirectory == projectPath else { return nil }
        return (panelIndex, tabIndex)
      }
    }
    guard let candidate = candidates.first(where: {
      snapshot.panels[$0.0].tabs[$0.1].role == .agent
    }) ?? candidates.first else {
      return false
    }
    snapshot.panels[candidate.0].tabs[candidate.1].role = .agent
    snapshot.panels[candidate.0].tabs[candidate.1].linkedSession = TerminalWorkspaceLinkedSessionSnapshot(
      provider: provider,
      sessionId: sessionId
    )
    restoredSnapshot = snapshot
    markedSessions.append("\(provider.rawValue.lowercased()):\(sessionId)")
    onWorkspaceChanged?(snapshot)
    return true
  }

  func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot? { restoredSnapshot }
  func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) { restoredSnapshot = snapshot }
}
