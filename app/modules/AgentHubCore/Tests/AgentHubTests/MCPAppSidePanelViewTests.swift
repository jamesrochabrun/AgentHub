import AgentHubMCPUI
import Foundation
import Testing

@testable import AgentHubCore

@Suite("MCP app side panel")
struct MCPAppSidePanelViewTests {
  @Test("Bridge pushes tool-input and tool-result once the app initializes")
  @MainActor
  func bridgePushesToolInputAndResultOnReady() {
    let invocation = MCPAppInvocation(
      id: "tu-1",
      serverName: "excalidraw",
      toolName: "create_view",
      arguments: .object(["elements": .array([.object(["type": .string("rectangle")])])]),
      result: .string("{\"checkpointId\":\"abc123\"}")
    )
    let handler = MCPAppHostBridgeHandler(
      resource: panelTestResource(source: .liveDiscovery),
      invocation: invocation,
      viewModel: nil,
      consentController: MCPAppConsentController(),
      onSizeChange: { _, _ in },
      onOperationNotice: { _ in },
      onTeardown: {}
    )

    let notifications = handler.appReadyNotifications()
    #expect(notifications.map(\.method) == [
      "ui/notifications/tool-input",
      "ui/notifications/tool-result"
    ])
    // tool-input carries the original tool arguments (the diagram elements).
    #expect(notifications[0].params?["arguments"]?["elements"]?.arrayValue?.count == 1)
    // tool-result exposes the JSON-string result as structuredContent for the app.
    #expect(notifications[1].params?["structuredContent"]?["checkpointId"] == .string("abc123"))
  }

  @Test("tool-result derives structuredContent from Codex Ok-wrapped content")
  @MainActor
  func toolResultDerivesStructuredContentFromContentBlocks() {
    // Codex unwraps to a result object with content blocks but no structuredContent.
    let codexResult = AgentHubMCPUIJSONValue.object([
      "content": .array([
        .object(["type": .string("text"), "text": .string("{\"checkpointId\":\"xyz\"}")])
      ])
    ])
    let params = MCPAppHostBridgeHandler.toolResultParams(from: codexResult)
    #expect(params["structuredContent"]?["checkpointId"] == .string("xyz"))
    #expect(params["content"]?.arrayValue?.count == 1)
  }

  @Test("Bridge pushes nothing when there is no originating invocation")
  @MainActor
  func bridgePushesNothingWithoutInvocation() {
    let handler = MCPAppHostBridgeHandler(
      resource: panelTestResource(source: .inlineJSONL),
      viewModel: nil,
      consentController: MCPAppConsentController(),
      onSizeChange: { _, _ in },
      onOperationNotice: { _ in },
      onTeardown: {}
    )
    #expect(handler.appReadyNotifications().isEmpty)
  }

  @Test("Consent controller remembers approvals for the current session")
  @MainActor
  func consentControllerRemembersApprovalsForCurrentSession() async throws {
    let controller = MCPAppConsentController()
    let resource = panelTestResource(source: .liveDiscovery)

    let approvalTask = Task { @MainActor in
      try await controller.require(.callTool("render"), resource: resource)
    }
    await waitForPendingRequest(controller)

    #expect(controller.pendingRequest?.action == .callTool("render"))
    controller.approvePendingRequest()
    try await approvalTask.value
    #expect(controller.pendingRequest == nil)

    try await controller.require(.callTool("render"), resource: resource)
    #expect(controller.pendingRequest == nil)
  }

  @Test("Consent controller denies pending requests")
  @MainActor
  func consentControllerDeniesPendingRequests() async throws {
    let controller = MCPAppConsentController()
    let resource = panelTestResource(source: .liveDiscovery)

    let denialTask = Task { @MainActor in
      try await controller.require(.readResource("ui://fake/secret"), resource: resource)
    }
    await waitForPendingRequest(controller)

    controller.denyPendingRequest()
    await #expect(throws: AgentHubMCPUIBridgeError.self) {
      try await denialTask.value
    }
    #expect(controller.pendingRequest == nil)
  }

  @Test("Consent controller auto-denies after the timeout instead of hanging")
  @MainActor
  func consentControllerAutoDeniesAfterTimeout() async {
    let controller = MCPAppConsentController(autoDenyTimeout: .milliseconds(50))
    let resource = panelTestResource(source: .inlineJSONL)

    await #expect(throws: AgentHubMCPUIBridgeError.self) {
      try await controller.require(.callTool("render"), resource: resource)
    }
    #expect(controller.pendingRequest == nil)
  }

  @Test("Cancelling pending consent resolves the awaiting request as denied")
  @MainActor
  func consentControllerCancelPendingDenies() async throws {
    let controller = MCPAppConsentController()
    let resource = panelTestResource(source: .inlineJSONL)

    let task = Task { @MainActor in
      try await controller.require(.callTool("render"), resource: resource)
    }
    await waitForPendingRequest(controller)

    controller.cancelPending()
    await #expect(throws: AgentHubMCPUIBridgeError.self) {
      try await task.value
    }
    #expect(controller.pendingRequest == nil)

    // A late approve must not crash or resume a second time.
    controller.approvePendingRequest()
    #expect(controller.pendingRequest == nil)
  }

  @Test("Bridge denies tool calls when no server can be resolved")
  @MainActor
  func bridgeDeniesToolCallsWithoutResolvableServer() async {
    let controller = MCPAppConsentController()
    var notices: [MCPAppPanelNotice] = []
    let handler = MCPAppHostBridgeHandler(
      resource: panelTestResource(source: .inlineJSONL),
      viewModel: nil,
      consentController: controller,
      onSizeChange: { _, _ in },
      onOperationNotice: { notices.append($0) },
      onTeardown: {}
    )

    await #expect(throws: AgentHubMCPUIBridgeError.self) {
      _ = try await handler.callTool(name: "render", arguments: .object([:]))
    }

    #expect(notices.first?.kind == .denied)
    #expect(notices.first?.title == "Tool Call Denied")
  }

  @Test("Bridge does not advertise tool calls without a resolvable server")
  @MainActor
  func bridgeHidesToolCallCapabilityWithoutServer() async throws {
    let handler = MCPAppHostBridgeHandler(
      resource: panelTestResource(source: .inlineJSONL),
      viewModel: nil,
      consentController: MCPAppConsentController(),
      onSizeChange: { _, _ in },
      onOperationNotice: { _ in },
      onTeardown: {}
    )

    let result = try await handler.initialize(params: .object([:]))
    #expect(result["capabilities"]?["tools"]?["call"] == .bool(false))
  }

  @Test("Bridge initialize includes MCP app SDK host fields")
  @MainActor
  func bridgeInitializeIncludesMCPAppSDKHostFields() async throws {
    let handler = MCPAppHostBridgeHandler(
      resource: panelTestResource(source: .liveDiscovery),
      viewModel: nil,
      consentController: MCPAppConsentController(),
      onSizeChange: { _, _ in },
      onOperationNotice: { _ in },
      onTeardown: {}
    )

    let result = try await handler.initialize(params: .object([
      "protocolVersion": .string("2025-11-21")
    ]))

    #expect(result["protocolVersion"] == .string("2025-11-21"))
    #expect(result["hostInfo"]?["name"] == .string("AgentHub"))
    #expect(result["hostCapabilities"]?["serverTools"] != nil)
    #expect(result["hostCapabilities"]?["serverResources"] != nil)
    #expect(result["hostCapabilities"]?["openLinks"] != nil)
    #expect(result["hostCapabilities"]?["sandbox"]?["permissions"]?["camera"] == nil)
    #expect(result["hostCapabilities"]?["sandbox"]?["csp"]?["connectDomains"] == .array([]))
    #expect(result["hostCapabilities"]?["sandbox"]?["csp"]?["connect_domains"] == nil)
    #expect(result["hostContext"]?["displayMode"] == .string("inline"))
    #expect(result["hostContext"]?["availableDisplayModes"]?.arrayValue?.contains(.string("fullscreen")) == true)
    #expect(result["host"]?["name"] == .string("AgentHub"))
    #expect(result["context"]?["resourceUri"] == .string("ui://fake/app"))
  }

  @Test("declaredHosts returns validated, deduped http(s) hosts in declaration order")
  func declaredHostsValidatesAndDedupes() {
    let csp = AgentHubMCPUICSP(
      connectDomains: ["https://api.example.com", "javascript:alert(1)", "https://api.example.com"],
      resourceDomains: ["https://cdn.example.com", "file:///x", "'self'"]
    )

    #expect(MCPAppNetworkConsent.declaredHosts(for: csp) == ["api.example.com", "cdn.example.com"])
  }

  @Test("declaredHosts is empty when the app declares no network domains")
  func declaredHostsEmptyByDefault() {
    #expect(MCPAppNetworkConsent.declaredHosts(for: AgentHubMCPUICSP()).isEmpty)
  }

  @Test("Consent banner shows only with declared hosts and no prior consent")
  func bannerVisibilityPredicate() {
    #expect(MCPAppNetworkConsent.shouldPrompt(hosts: ["example.com"], consented: false))
    #expect(!MCPAppNetworkConsent.shouldPrompt(hosts: ["example.com"], consented: true))
    #expect(!MCPAppNetworkConsent.shouldPrompt(hosts: [], consented: false))
  }

  @MainActor
  private func waitForPendingRequest(_ controller: MCPAppConsentController) async {
    for _ in 0..<50 {
      if controller.pendingRequest != nil { return }
      await Task.yield()
    }
  }

  private func panelTestResource(source: MCPAppResourceSource) -> MCPAppResource {
    MCPAppResource(
      provider: .claude,
      projectPath: "/tmp/project",
      serverName: "fake",
      title: "Fake App",
      source: source,
      resource: AgentHubMCPUIResource(
        uri: "ui://fake/app",
        text: "<main>Fake</main>",
        metadata: AgentHubMCPUIResourceMetadata(
          title: "Fake App",
          permissions: AgentHubMCPUIPermissions(
            allowOpenLinks: true,
            allowedToolNames: ["render"]
          )
        )
      )
    )
  }
}
