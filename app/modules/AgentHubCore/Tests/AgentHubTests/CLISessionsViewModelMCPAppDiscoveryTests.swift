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

/// On-demand gateway mock. Discovery (snapshot) is gone; this only records the
/// lazy callbacks a rendered MCP app makes back to its server.
private actor RecordingMCPAppDiscoveryService: MCPAppDiscoveryServiceProtocol {
  struct ToolCall: Equatable {
    let provider: SessionProviderKind
    let projectPath: String
    let serverName: String
    let name: String
  }

  private(set) var toolCalls: [ToolCall] = []

  func callTool(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    name: String,
    arguments: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    toolCalls.append(ToolCall(provider: provider, projectPath: projectPath, serverName: serverName, name: name))
    return .object(["ok": .bool(true)])
  }

  func listResources(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue {
    .object([:])
  }

  func listTools(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue {
    // Mirrors the real excalidraw server: create_view declares a `ui://` app.
    .object([
      "tools": .array([
        .object([
          "name": .string("create_view"),
          "title": .string("Draw Diagram"),
          "_meta": .object([
            "ui": .object(["resourceUri": .string("ui://excalidraw/mcp-app.html")])
          ])
        ]),
        .object(["name": .string("read_me")])
      ])
    ])
  }

  func readResource(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    uri: String
  ) async throws -> AgentHubMCPUIJSONValue {
    .object([
      "contents": .array([
        .object([
          "uri": .string(uri),
          "mimeType": .string(AgentHubMCPUIResource.htmlAppMimeType),
          "text": .string("<main>shell</main>")
        ])
      ])
    ])
  }

  func recordedToolCalls() -> [ToolCall] {
    toolCalls
  }
}

@Suite("CLISessionsViewModel MCP app resources")
struct CLISessionsViewModelMCPAppDiscoveryTests {
  @MainActor
  private func makeViewModel(
    provider: SessionProviderKind,
    service: any MCPAppDiscoveryServiceProtocol
  ) -> CLISessionsViewModel {
    CLISessionsViewModel(
      monitorService: MCPAppViewModelMonitorService(),
      fileWatcher: MCPAppViewModelFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(
        command: provider == .codex ? "codex" : "claude",
        mode: provider == .codex ? .codex : .claude
      ),
      providerKind: provider,
      mcpAppDiscoveryService: service,
      approvalNotificationService: NoOpApprovalNotificationService()
    )
  }

  @MainActor
  private func waitForPendingRequest(_ controller: MCPAppConsentController) async {
    for _ in 0..<50 {
      if controller.pendingRequest != nil { return }
      await Task.yield()
    }
  }

  @Test("Network grants persist per app for the launch and ignore host order")
  @MainActor
  func networkGrantPersistsPerApp() {
    let viewModel = makeViewModel(provider: .claude, service: RecordingMCPAppDiscoveryService())

    // Nothing granted up front; an empty host set is never grantable.
    #expect(!viewModel.isMCPAppNetworkGranted(serverName: "excalidraw", hosts: ["esm.sh"]))
    viewModel.grantMCPAppNetwork(serverName: "excalidraw", hosts: [])
    #expect(!viewModel.isMCPAppNetworkGranted(serverName: "excalidraw", hosts: []))

    viewModel.grantMCPAppNetwork(serverName: "excalidraw", hosts: ["esm.sh", "cdn.example.com"])

    // Same app + same host set (any order) is remembered.
    #expect(viewModel.isMCPAppNetworkGranted(serverName: "excalidraw", hosts: ["cdn.example.com", "esm.sh"]))
    // A different server, or a changed host set, still prompts.
    #expect(!viewModel.isMCPAppNetworkGranted(serverName: "other", hosts: ["esm.sh", "cdn.example.com"]))
    #expect(!viewModel.isMCPAppNetworkGranted(serverName: "excalidraw", hosts: ["esm.sh"]))
  }

  @Test("Builds inline MCP app resources from agent tool results")
  @MainActor
  func buildsInlineResourcesFromState() async {
    let projectPath = "/tmp/agenthub-mcp-project"
    let viewModel = makeViewModel(provider: .claude, service: RecordingMCPAppDiscoveryService())
    let session = CLISession(id: "session-1", projectPath: projectPath)

    #expect(viewModel.mcpAppResources(for: session, state: nil).isEmpty)

    let state = SessionMonitorState(detectedMCPAppResources: [
      MCPAppResourceDescriptor(
        serverName: "docs",
        uri: "ui://docs/app",
        title: "Docs",
        text: "<main>Docs</main>"
      ),
      MCPAppResourceDescriptor(
        serverName: "charts",
        uri: "ui://charts/app",
        text: "<main>Charts</main>"
      )
    ])

    let resources = viewModel.mcpAppResources(for: session, state: state)
    #expect(resources.map(\.resource.uri).sorted() == ["ui://charts/app", "ui://docs/app"])

    let docs = resources.first { $0.resource.uri == "ui://docs/app" }
    #expect(docs?.serverName == "docs")
    #expect(docs?.source == .inlineJSONL)
    #expect(docs?.title == "Docs")
  }

  @Test("Drops detected descriptors without inline HTML")
  @MainActor
  func dropsDescriptorsWithoutText() async {
    let projectPath = "/tmp/agenthub-mcp-project"
    let viewModel = makeViewModel(provider: .claude, service: RecordingMCPAppDiscoveryService())
    let session = CLISession(id: "session-1", projectPath: projectPath)

    let state = SessionMonitorState(detectedMCPAppResources: [
      MCPAppResourceDescriptor(serverName: "docs", uri: "ui://docs/app", text: nil)
    ])

    #expect(viewModel.mcpAppResources(for: session, state: state).isEmpty)
  }

  @Test("Routes inline MCP app tool calls to the on-demand server gateway")
  @MainActor
  func routesInlineToolCallsToServer() async throws {
    let service = RecordingMCPAppDiscoveryService()
    let viewModel = makeViewModel(provider: .claude, service: service)
    let resource = MCPAppResource(
      provider: .claude,
      projectPath: "/tmp/agenthub-mcp-project",
      serverName: "docs",
      source: .inlineJSONL,
      resource: AgentHubMCPUIResource(uri: "ui://docs/app", text: "<main/>")
    )

    let result = try await viewModel.callMCPAppTool(resource: resource, name: "render", arguments: .object([:]))

    #expect(result["ok"] == .bool(true))
    #expect(await service.recordedToolCalls() == [
      .init(provider: .claude, projectPath: "/tmp/agenthub-mcp-project", serverName: "docs", name: "render")
    ])
  }

  @Test("Inline bridge advertises tool calls and routes them once approved")
  @MainActor
  func inlineBridgeAdvertisesAndRoutesToolCalls() async throws {
    let service = RecordingMCPAppDiscoveryService()
    let viewModel = makeViewModel(provider: .claude, service: service)
    let controller = MCPAppConsentController(autoDenyTimeout: .seconds(5))
    let resource = MCPAppResource(
      provider: .claude,
      projectPath: "/tmp/agenthub-mcp-project",
      serverName: "docs",
      source: .inlineJSONL,
      resource: AgentHubMCPUIResource(
        uri: "ui://docs/app",
        text: "<main/>",
        metadata: AgentHubMCPUIResourceMetadata(
          permissions: AgentHubMCPUIPermissions(allowedToolNames: ["render"])
        )
      )
    )
    let handler = MCPAppHostBridgeHandler(
      resource: resource,
      viewModel: viewModel,
      consentController: controller,
      onSizeChange: { _, _ in },
      onOperationNotice: { _ in },
      onTeardown: {}
    )

    let initialize = try await handler.initialize(params: .object([:]))
    #expect(initialize["capabilities"]?["tools"]?["call"] == .bool(true))

    let callTask = Task { @MainActor in
      try await handler.callTool(name: "render", arguments: .object([:]))
    }
    await waitForPendingRequest(controller)
    controller.approvePendingRequest()
    let result = try await callTask.value

    #expect(result["ok"] == .bool(true))
    #expect(await service.recordedToolCalls().map(\.name) == ["render"])
  }

  @Test("Display items include resources embedded directly in the JSONL")
  @MainActor
  func displayItemsIncludeEmbeddedResources() {
    let viewModel = makeViewModel(provider: .claude, service: RecordingMCPAppDiscoveryService())
    let session = CLISession(id: "session-1", projectPath: "/tmp/agenthub-mcp-project")

    #expect(viewModel.mcpAppDisplayItems(for: session, state: nil).isEmpty)

    let state = SessionMonitorState(detectedMCPAppResources: [
      MCPAppResourceDescriptor(serverName: "docs", uri: "ui://docs/app", title: "Docs", text: "<main/>")
    ])
    let items = viewModel.mcpAppDisplayItems(for: session, state: state)
    #expect(items.count == 1)
    #expect(items.first?.invocation == nil)
    #expect(items.first?.resource.resource.uri == "ui://docs/app")
  }

  @Test("Resolves an app-bearing tool call into a render item with the fetched shell")
  @MainActor
  func resolvesAppBearingInvocationIntoRenderItem() async {
    let viewModel = makeViewModel(provider: .claude, service: RecordingMCPAppDiscoveryService())
    let session = CLISession(id: "session-1", projectPath: "/tmp/agenthub-mcp-project")
    let state = SessionMonitorState(detectedMCPAppInvocations: [
      MCPAppInvocation(
        id: "tu-1",
        serverName: "excalidraw",
        toolName: "create_view",
        arguments: .object(["elements": .array([])]),
        result: .string("{\"checkpointId\":\"abc123\"}")
      )
    ])

    // Before resolution there is nothing to render (shell not fetched yet).
    #expect(viewModel.mcpAppRenderItems(for: session, state: state).isEmpty)

    await viewModel.ensureMCPAppRenderItems(for: session, state: state)

    let items = viewModel.mcpAppRenderItems(for: session, state: state)
    #expect(items.count == 1)
    let item = items.first
    #expect(item?.resource.resource.uri == "ui://excalidraw/mcp-app.html")
    #expect(item?.resource.resource.text == "<main>shell</main>")
    #expect(item?.resource.title == "Draw Diagram")
    #expect(item?.invocation?.id == "tu-1")
  }

  @Test("Derives a diagram title from the drawing's first text element")
  @MainActor
  func derivesTitleFromDiagramContent() {
    let stringElements = MCPAppInvocation(
      id: "t1",
      serverName: "excalidraw",
      toolName: "create_view",
      arguments: .object([
        "elements": .string("[{\"type\":\"cameraUpdate\"},{\"type\":\"text\",\"text\":\"Login Flow\"}]")
      ])
    )
    #expect(CLISessionsViewModel.deriveMCPAppTitle(from: stringElements) == "Login Flow")

    let arrayElements = MCPAppInvocation(
      id: "t2",
      serverName: "excalidraw",
      toolName: "create_view",
      arguments: .object([
        "elements": .array([
          .object(["type": .string("rectangle"), "label": .object(["text": .string("Start")])])
        ])
      ])
    )
    #expect(CLISessionsViewModel.deriveMCPAppTitle(from: arrayElements) == "Start")

    let noText = MCPAppInvocation(
      id: "t3",
      serverName: "excalidraw",
      toolName: "create_view",
      arguments: .object(["elements": .array([.object(["type": .string("rectangle")])])])
    )
    #expect(CLISessionsViewModel.deriveMCPAppTitle(from: noText) == nil)
  }
}
