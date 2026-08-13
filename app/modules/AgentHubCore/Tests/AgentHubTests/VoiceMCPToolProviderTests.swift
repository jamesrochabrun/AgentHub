import AgentHubMCPUI
import AgentHubVoice
import Foundation
import Testing
@testable import AgentHubCore

private struct StubResolver: MCPServerConfigurationResolverProtocol {
  let claude: [MCPServerConfiguration]
  let codex: [MCPServerConfiguration]

  func serverConfigurations(
    provider: SessionProviderKind,
    projectPath: String
  ) async -> [MCPServerConfiguration] {
    provider == .claude ? claude : codex
  }
}

private struct StubError: LocalizedError {
  var errorDescription: String? { "boom" }
}

private actor StubDiscovery: MCPAppDiscoveryServiceProtocol {
  private var toolsByServer: [String: AgentHubMCPUIJSONValue] = [:]
  private var callToolResult: AgentHubMCPUIJSONValue = .object([:])
  private var callToolError: Error?
  private var callToolDelaySeconds: Double = 0
  private(set) var listToolsServers: [String] = []
  private(set) var callRequests: [
    (provider: SessionProviderKind, server: String, tool: String, arguments: AgentHubMCPUIJSONValue?)
  ] = []

  func setToolList(server: String, json: String) throws {
    toolsByServer[server] = try JSONDecoder().decode(
      AgentHubMCPUIJSONValue.self,
      from: Data(json.utf8)
    )
  }

  func setCallResult(json: String) throws {
    callToolResult = try JSONDecoder().decode(
      AgentHubMCPUIJSONValue.self,
      from: Data(json.utf8)
    )
  }

  func setCallError(_ error: Error?) {
    callToolError = error
  }

  func setCallDelay(seconds: Double) {
    callToolDelaySeconds = seconds
  }

  func callTool(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    name: String,
    arguments: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    callRequests.append((provider, serverName, name, arguments))
    if callToolDelaySeconds > 0 {
      try await Task.sleep(nanoseconds: UInt64(callToolDelaySeconds * 1_000_000_000))
    }
    if let callToolError {
      throw callToolError
    }
    return callToolResult
  }

  func readResource(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    uri: String
  ) async throws -> AgentHubMCPUIJSONValue {
    .null
  }

  func listResources(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue {
    .null
  }

  func listTools(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue {
    listToolsServers.append(serverName)
    guard let tools = toolsByServer[serverName] else {
      throw MCPAppDiscoveryError.serverNotFound(serverName)
    }
    return tools
  }
}

@MainActor
struct VoiceMCPToolProviderTests {
  private func stdioConfig(
    _ name: String,
    provider: SessionProviderKind = .claude
  ) -> MCPServerConfiguration {
    MCPServerConfiguration(
      provider: provider,
      projectPath: "/Users/test",
      name: name,
      command: "/usr/bin/true"
    )
  }

  private func makeProvider(
    resolver: StubResolver,
    discovery: StubDiscovery,
    enabled: Set<String>,
    toolCallTimeoutSeconds: TimeInterval = 5,
    maxOutputCharacters: Int = 6_000
  ) -> VoiceMCPToolProvider {
    VoiceMCPToolProvider(
      resolver: resolver,
      discovery: discovery,
      enabledServerNames: { enabled },
      scopePath: "/Users/test",
      toolCallTimeoutSeconds: toolCallTimeoutSeconds,
      maxOutputCharacters: maxOutputCharacters
    )
  }

  private let slackToolsJSON = """
    {"tools":[{"name":"send_message","description":"Send a Slack message.",\
    "inputSchema":{"type":"object","properties":{"channel":{"type":"string"}},\
    "required":["channel"]}}]}
    """

  @Test
  func refreshBuildsNamespacedToolsForEnabledSupportedServersOnly() async throws {
    let unsupported = MCPServerConfiguration(
      provider: .claude,
      projectPath: "/Users/test",
      name: "figma",
      transport: .unsupportedAuthentication("Auth not supported.")
    )
    let resolver = StubResolver(
      claude: [stdioConfig("slack"), unsupported],
      codex: [stdioConfig("slack", provider: .codex), stdioConfig("docs", provider: .codex)]
    )
    let discovery = StubDiscovery()
    try await discovery.setToolList(server: "slack", json: slackToolsJSON)
    try await discovery.setToolList(
      server: "docs",
      json: #"{"tools":[{"name":"search"}]}"#
    )
    let provider = makeProvider(
      resolver: resolver,
      discovery: discovery,
      enabled: ["slack", "docs", "figma"]
    )

    await provider.refresh()
    let tools = provider.currentTools()

    #expect(tools.map(\.name) == ["slack__send_message", "docs__search"])
    #expect(tools.allSatisfy { $0.parameters["type"] != nil })
    // The unsupported server is never contacted; the duplicated slack entry
    // resolves through Claude, not Codex.
    #expect(await discovery.listToolsServers == ["slack", "docs"])
    let slackTool = try #require(tools.first)
    #expect(slackTool.description.contains("[slack]"))
    _ = await VoiceToolRegistry(tools: tools).execute(
      name: "slack__send_message",
      arguments: #"{"channel":"general"}"#
    )
    let call = try #require(await discovery.callRequests.first)
    #expect(call.provider == .claude)
  }

  @Test
  func handlerProxiesCallToolAndEncodesTextOutput() async throws {
    let resolver = StubResolver(claude: [stdioConfig("slack")], codex: [])
    let discovery = StubDiscovery()
    try await discovery.setToolList(server: "slack", json: slackToolsJSON)
    try await discovery.setCallResult(
      json: #"{"content":[{"type":"text","text":"posted to #general"}],"isError":false}"#
    )
    let provider = makeProvider(resolver: resolver, discovery: discovery, enabled: ["slack"])
    await provider.refresh()
    let registry = VoiceToolRegistry(tools: provider.currentTools())

    let output = await registry.execute(
      name: "slack__send_message",
      arguments: #"{"channel":"general"}"#
    )

    #expect(output.contains(#""status":"ok""#))
    #expect(output.contains("posted to #general"))
    let call = try #require(await discovery.callRequests.first)
    #expect(call.server == "slack")
    #expect(call.tool == "send_message")
    let arguments = try #require(call.arguments?.jsonObject as? [String: Any])
    #expect(arguments["channel"] as? String == "general")
  }

  @Test
  func handlerSurfacesErrorsAndTimeoutsAsErrorJSON() async throws {
    let resolver = StubResolver(claude: [stdioConfig("slack")], codex: [])
    let discovery = StubDiscovery()
    try await discovery.setToolList(server: "slack", json: slackToolsJSON)
    await discovery.setCallError(StubError())
    let provider = makeProvider(
      resolver: resolver,
      discovery: discovery,
      enabled: ["slack"],
      toolCallTimeoutSeconds: 0.05
    )
    await provider.refresh()
    let registry = VoiceToolRegistry(tools: provider.currentTools())

    let failed = await registry.execute(
      name: "slack__send_message",
      arguments: #"{"channel":"general"}"#
    )
    #expect(failed.contains(#""status":"error""#))
    #expect(failed.contains("boom"))

    await discovery.setCallError(nil)
    await discovery.setCallDelay(seconds: 2)
    let timedOut = await registry.execute(
      name: "slack__send_message",
      arguments: #"{"channel":"general"}"#
    )
    #expect(timedOut.contains(#""status":"error""#))
    #expect(timedOut.contains("timed out"))
  }

  @Test
  func longAndErrorToolResultsAreEncodedFaithfully() async throws {
    let resolver = StubResolver(claude: [stdioConfig("slack")], codex: [])
    let discovery = StubDiscovery()
    try await discovery.setToolList(server: "slack", json: slackToolsJSON)
    let longText = String(repeating: "x", count: 50)
    try await discovery.setCallResult(
      json: #"{"content":[{"type":"text","text":"\#(longText)"}],"isError":true}"#
    )
    let provider = makeProvider(
      resolver: resolver,
      discovery: discovery,
      enabled: ["slack"],
      maxOutputCharacters: 10
    )
    await provider.refresh()
    let registry = VoiceToolRegistry(tools: provider.currentTools())

    let output = await registry.execute(
      name: "slack__send_message",
      arguments: #"{"channel":"general"}"#
    )

    #expect(output.contains(#""status":"tool_error""#))
    #expect(output.contains(#""truncated":true"#))
    #expect(!output.contains(longText))
  }

  @Test
  func emptyEnabledListClearsToolsWithoutContactingServers() async throws {
    let resolver = StubResolver(claude: [stdioConfig("slack")], codex: [])
    let discovery = StubDiscovery()
    try await discovery.setToolList(server: "slack", json: slackToolsJSON)
    let provider = makeProvider(resolver: resolver, discovery: discovery, enabled: [])

    await provider.refresh()

    #expect(provider.currentTools().isEmpty)
    #expect(await discovery.listToolsServers.isEmpty)
  }

  @Test
  func discoverServersMergesProvidersAndFlagsUnsupported() async throws {
    let unsupported = MCPServerConfiguration(
      provider: .claude,
      projectPath: "/Users/test",
      name: "figma",
      transport: .unsupportedAuthentication("Auth not supported.")
    )
    let resolver = StubResolver(
      claude: [stdioConfig("slack"), unsupported],
      codex: [stdioConfig("slack", provider: .codex)]
    )
    let provider = makeProvider(
      resolver: resolver,
      discovery: StubDiscovery(),
      enabled: []
    )

    let servers = await provider.discoverServers()

    #expect(servers.map(\.name) == ["slack", "figma"])
    #expect(servers.first?.providers == [.claude, .codex])
    #expect(servers.first?.isSupported == true)
    #expect(servers.last?.isSupported == false)
    #expect(servers.last?.unsupportedReason == "Auth not supported.")
  }

  @Test
  func namespacedToolNameSanitizesAndTruncates() {
    #expect(
      VoiceMCPToolProvider.namespacedToolName(server: "slack", tool: "send_message")
        == "slack__send_message"
    )
    #expect(
      VoiceMCPToolProvider.namespacedToolName(server: "my server!", tool: "do.it")
        == "my_server___do_it"
    )
    let long = VoiceMCPToolProvider.namespacedToolName(
      server: String(repeating: "s", count: 80),
      tool: "tool"
    )
    #expect(long.count == 64)
    #expect(long.hasSuffix("__tool"))
    let hugeTool = VoiceMCPToolProvider.namespacedToolName(
      server: "srv",
      tool: String(repeating: "t", count: 80)
    )
    #expect(hugeTool.count == 64)
  }

  @Test
  func functionSchemaFallsBackToEmptyObjectSchema() {
    let missing = VoiceMCPToolProvider.functionSchema(from: nil)
    #expect(stringValue(missing["type"]) == "object")
    #expect(boolValue(missing["additionalProperties"]) == false)

    let untyped = VoiceMCPToolProvider.functionSchema(
      from: ["properties": ["a": ["type": "string"]]]
    )
    #expect(stringValue(untyped["type"]) == "object")
    #expect(untyped["properties"] != nil)
  }

  private func stringValue(_ value: VoiceJSONValue?) -> String? {
    if case .string(let string)? = value {
      return string
    }
    return nil
  }

  private func boolValue(_ value: VoiceJSONValue?) -> Bool? {
    if case .bool(let bool)? = value {
      return bool
    }
    return nil
  }
}
