import AgentHubMCPUI
import Foundation
import Testing

@testable import AgentHubCore

@Suite("MCP Apps panel")
struct MCPAppsPanelViewTests {
  @Test("Consent controller remembers approvals for the current panel")
  @MainActor
  func consentControllerRemembersApprovalsForCurrentPanel() async throws {
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

  @Test("Bridge reports denied tool calls")
  @MainActor
  func bridgeReportsDeniedToolCalls() async {
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

  @MainActor
  private func waitForPendingRequest(_ controller: MCPAppConsentController) async {
    for _ in 0..<10 {
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
