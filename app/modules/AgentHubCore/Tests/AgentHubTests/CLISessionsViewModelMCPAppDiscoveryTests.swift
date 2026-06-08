import AgentHubMCPUI
import Combine
import Foundation
import Testing

@testable import AgentHubCore

private final class MCPAppViewModelMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<[SelectedRepository], Never>()

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class MCPAppViewModelFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()

  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

private actor MockMCPAppDiscoveryService: MCPAppDiscoveryServiceProtocol {
  private let resources: [MCPAppResource]
  private var discoverCount = 0

  init(resources: [MCPAppResource]) {
    self.resources = resources
  }

  func discoverResources(
    provider: SessionProviderKind,
    projectPath: String,
    forceRefresh: Bool
  ) async -> [MCPAppResource] {
    discoverCount += 1
    return resources.filter { $0.provider == provider && $0.projectPath == projectPath }
  }

  func callTool(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    name: String,
    arguments: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    .object(["ok": .bool(true)])
  }

  func readResource(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    uri: String
  ) async throws -> AgentHubMCPUIJSONValue {
    .object([:])
  }

  func listResources(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue {
    .object([:])
  }

  func discoveryCallCount() -> Int {
    discoverCount
  }
}

@Suite("CLISessionsViewModel MCP app discovery")
struct CLISessionsViewModelMCPAppDiscoveryTests {
  @Test("Caches live-discovered MCP app resources for session UI")
  @MainActor
  func cachesLiveDiscoveredResourcesForSessionUI() async {
    let projectPath = "/tmp/agenthub-mcp-project"
    let liveResource = MCPAppResource(
      provider: .claude,
      projectPath: projectPath,
      serverName: "charts",
      title: "Dashboard",
      source: .liveDiscovery,
      resource: AgentHubMCPUIResource(
        uri: "ui://charts/dashboard",
        text: "<main>Dashboard</main>"
      )
    )
    let discoveryService = MockMCPAppDiscoveryService(resources: [liveResource])
    let viewModel = CLISessionsViewModel(
      monitorService: MCPAppViewModelMonitorService(),
      fileWatcher: MCPAppViewModelFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      mcpAppDiscoveryService: discoveryService,
      approvalNotificationService: NoOpApprovalNotificationService()
    )
    let session = CLISession(id: "session-1", projectPath: projectPath)

    #expect(viewModel.mcpAppResources(for: session, state: nil).isEmpty)

    await viewModel.ensureMCPAppResources(for: session)

    let resources = viewModel.mcpAppResources(for: session, state: nil)
    #expect(resources.map(\.resource.uri) == ["ui://charts/dashboard"])
    #expect(resources.first?.serverName == "charts")

    await viewModel.ensureMCPAppResources(for: session)
    #expect(await discoveryService.discoveryCallCount() == 1)
  }

  @Test("Merges live-discovered resources with inline JSONL resources")
  @MainActor
  func mergesLiveAndInlineResources() async {
    let projectPath = "/tmp/agenthub-mcp-project"
    let liveResource = MCPAppResource(
      provider: .codex,
      projectPath: projectPath,
      serverName: "charts",
      title: "Dashboard",
      source: .liveDiscovery,
      resource: AgentHubMCPUIResource(
        uri: "ui://charts/dashboard",
        text: "<main>Dashboard</main>"
      )
    )
    let discoveryService = MockMCPAppDiscoveryService(resources: [liveResource])
    let viewModel = CLISessionsViewModel(
      monitorService: MCPAppViewModelMonitorService(),
      fileWatcher: MCPAppViewModelFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      mcpAppDiscoveryService: discoveryService,
      approvalNotificationService: NoOpApprovalNotificationService()
    )
    let session = CLISession(id: "session-1", projectPath: projectPath)
    await viewModel.ensureMCPAppResources(for: session)

    let state = SessionMonitorState(detectedMCPAppResources: [
      MCPAppResourceDescriptor(
        uri: "ui://inline/form",
        title: "Inline Form",
        text: "<main>Inline</main>"
      )
    ])

    let resources = viewModel.mcpAppResources(for: session, state: state)
    #expect(resources.map(\.resource.uri).sorted() == [
      "ui://charts/dashboard",
      "ui://inline/form"
    ])
  }
}
