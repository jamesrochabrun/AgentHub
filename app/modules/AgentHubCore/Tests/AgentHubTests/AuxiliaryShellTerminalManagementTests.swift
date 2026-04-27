import AppKit
import Canvas
import Combine
import Foundation
import Testing

@testable import AgentHubCore

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
  terminalBackend: EmbeddedTerminalBackend = .storedPreference
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: AuxiliaryShellStubMonitorService(),
    fileWatcher: AuxiliaryShellStubFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService(),
    terminalSurfaceFactory: terminalSurfaceFactory,
    terminalBackend: terminalBackend
  )
}

@MainActor
private final class TestTerminalSurface: NSView, EmbeddedTerminalSurface {
  var view: NSView { self }
  var currentProcessPID: Int32?
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  private(set) var configuredProjectPath: String?
  private(set) var configuredShellPath: String?
  private(set) var configureCallCount = 0
  private(set) var terminateCallCount = 0

  func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {}

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
  ) {
    configuredProjectPath = projectPath
    configureCallCount += 1
  }

  func configureShell(projectPath: String, isDark: Bool, shellPath: String?) {
    configuredProjectPath = projectPath
    configuredShellPath = shellPath
    configureCallCount += 1
  }

  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration) {}

  func terminateProcess() {
    terminateCallCount += 1
  }

  func resetPromptDeliveryFlag() {}
  func sendPromptIfNeeded(_ prompt: String) {}
  func submitPromptImmediately(_ prompt: String) -> Bool { true }
  func typeText(_ text: String) {}
  func typeInitialTextIfNeeded(_ text: String) {}
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {}
  func focus() {}
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
