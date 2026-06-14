//
//  MCPConnectorInstallServiceTests.swift
//  AgentHub
//

import Foundation
import Testing

@testable import AgentHubCore

@Suite("MCP connector install service")
struct MCPConnectorInstallServiceTests {

  @Test("Install writes Excalidraw to Claude and Codex global configs")
  func installWritesExcalidrawGlobalConfigs() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let claudeConfig = directory.appending(path: "claude.json")
    let codexConfig = directory.appending(path: "codex/config.toml")
    let service = MCPConnectorInstallService(
      claudeConfigPath: claudeConfig.path,
      codexConfigPath: codexConfig.path
    )

    let before = await service.installationStatus(for: MCPConnectorCatalog.excalidraw)
    #expect(!before.isGloballyInstalled)

    try await service.install(MCPConnectorCatalog.excalidraw)

    let after = await service.installationStatus(for: MCPConnectorCatalog.excalidraw)
    #expect(after.isGloballyInstalled)

    let resolver = DefaultMCPServerConfigurationResolver(
      claudeConfigPath: claudeConfig.path,
      codexConfigPath: codexConfig.path
    )

    let claudeServers = await resolver.serverConfigurations(provider: .claude, projectPath: directory.path)
    let claudeExcalidraw = try #require(claudeServers.first { $0.name == "excalidraw" })
    assertHTTPTransport(claudeExcalidraw.transport)

    let codexServers = await resolver.serverConfigurations(provider: .codex, projectPath: directory.path)
    let codexExcalidraw = try #require(codexServers.first { $0.name == "excalidraw" })
    assertHTTPTransport(codexExcalidraw.transport)
  }

  @Test("Remove deletes only Excalidraw and preserves unrelated MCP servers")
  func removePreservesUnrelatedMCPServers() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let claudeConfig = directory.appending(path: "claude.json")
    try """
    {
      "theme": "dark",
      "mcpServers": {
        "existing": {
          "command": "node",
          "args": ["server.js"]
        },
        "excalidraw": {
          "type": "http",
          "url": "https://mcp.excalidraw.com/mcp"
        }
      }
    }
    """.write(to: claudeConfig, atomically: true, encoding: .utf8)

    let codexConfig = directory.appending(path: "codex/config.toml")
    try FileManager.default.createDirectory(
      at: codexConfig.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    model = "gpt-5-codex"

    [mcp_servers.existing]
    command = "node"
    args = ["server.js"]

    [mcp_servers.excalidraw]
    type = "http"
    url = "https://mcp.excalidraw.com/mcp"

    [mcp_servers.excalidraw.env]
    TOKEN = "removed-with-server"
    """.write(to: codexConfig, atomically: true, encoding: .utf8)

    let service = MCPConnectorInstallService(
      claudeConfigPath: claudeConfig.path,
      codexConfigPath: codexConfig.path
    )

    try await service.remove(MCPConnectorCatalog.excalidraw)

    let after = await service.installationStatus(for: MCPConnectorCatalog.excalidraw)
    #expect(!after.isGloballyInstalled)
    #expect(after.claude == .missing)
    #expect(after.codex == .missing)

    let claudeData = try Data(contentsOf: claudeConfig)
    let claudeRoot = try #require(JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
    #expect(claudeRoot["theme"] as? String == "dark")
    let claudeServers = try #require(claudeRoot["mcpServers"] as? [String: Any])
    #expect(claudeServers["existing"] != nil)
    #expect(claudeServers["excalidraw"] == nil)

    let codexContent = try String(contentsOf: codexConfig, encoding: .utf8)
    #expect(codexContent.contains(#"model = "gpt-5-codex""#))
    #expect(codexContent.contains("[mcp_servers.existing]"))
    #expect(!codexContent.contains("excalidraw"))
  }

  @Test("Install repairs stale Excalidraw entries")
  func installRepairsStaleEntries() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let claudeConfig = directory.appending(path: "claude.json")
    try """
    {
      "mcpServers": {
        "excalidraw": {
          "type": "sse",
          "url": "https://old.example.com/sse"
        }
      }
    }
    """.write(to: claudeConfig, atomically: true, encoding: .utf8)

    let codexConfig = directory.appending(path: "codex/config.toml")
    try FileManager.default.createDirectory(
      at: codexConfig.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    [mcp_servers.excalidraw]
    type = "sse"
    url = "https://old.example.com/sse"
    """.write(to: codexConfig, atomically: true, encoding: .utf8)

    let service = MCPConnectorInstallService(
      claudeConfigPath: claudeConfig.path,
      codexConfigPath: codexConfig.path
    )

    let before = await service.installationStatus(for: MCPConnectorCatalog.excalidraw)
    #expect(before.claude == .needsUpdate)
    #expect(before.codex == .needsUpdate)

    try await service.install(MCPConnectorCatalog.excalidraw)

    let after = await service.installationStatus(for: MCPConnectorCatalog.excalidraw)
    #expect(after.isGloballyInstalled)
  }
}

@MainActor
@Suite("Connectors settings view model")
struct ConnectorsSettingsViewModelTests {

  @Test("Toggle installs when connector is not globally installed")
  func toggleInstallsMissingConnector() async {
    let service = FakeMCPConnectorInstallService(
      status: MCPConnectorInstallationStatus(claude: .missing, codex: .missing)
    )
    let viewModel = ConnectorsSettingsViewModel()

    await viewModel.load(service: service)
    #expect(viewModel.actionTitle(for: MCPConnectorCatalog.excalidraw) == "Add")

    await viewModel.toggle(MCPConnectorCatalog.excalidraw)

    #expect(viewModel.actionTitle(for: MCPConnectorCatalog.excalidraw) == "Remove")
    #expect(await service.installCount == 1)
    #expect(await service.removeCount == 0)
  }

  @Test("Toggle removes when connector is globally installed")
  func toggleRemovesInstalledConnector() async {
    let service = FakeMCPConnectorInstallService(
      status: MCPConnectorInstallationStatus(claude: .installed, codex: .installed)
    )
    let viewModel = ConnectorsSettingsViewModel()

    await viewModel.load(service: service)
    #expect(viewModel.actionTitle(for: MCPConnectorCatalog.excalidraw) == "Remove")

    await viewModel.toggle(MCPConnectorCatalog.excalidraw)

    #expect(viewModel.actionTitle(for: MCPConnectorCatalog.excalidraw) == "Add")
    #expect(await service.installCount == 0)
    #expect(await service.removeCount == 1)
  }
}

private func assertHTTPTransport(_ transport: MCPServerTransport) {
  if case .streamableHTTP(let endpoint, let legacySSEFallback) = transport {
    #expect(endpoint.absoluteString == "https://mcp.excalidraw.com/mcp")
    #expect(legacySSEFallback)
  } else {
    Issue.record("Expected streamable HTTP transport")
  }
}

private actor FakeMCPConnectorInstallService: MCPConnectorInstallServiceProtocol {
  private var status: MCPConnectorInstallationStatus
  private(set) var installCount = 0
  private(set) var removeCount = 0

  init(status: MCPConnectorInstallationStatus) {
    self.status = status
  }

  func installationStatus(for connector: MCPConnectorDefinition) async -> MCPConnectorInstallationStatus {
    status
  }

  func install(_ connector: MCPConnectorDefinition) async throws {
    installCount += 1
    status = MCPConnectorInstallationStatus(claude: .installed, codex: .installed)
  }

  func remove(_ connector: MCPConnectorDefinition) async throws {
    removeCount += 1
    status = MCPConnectorInstallationStatus(claude: .missing, codex: .missing)
  }
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentHubConnectorTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
