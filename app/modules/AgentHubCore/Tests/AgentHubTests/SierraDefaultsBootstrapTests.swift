import Foundation
import Testing

@testable import AgentHubCore

@Suite("Sierra defaults bootstrap", .serialized)
struct SierraDefaultsBootstrapTests {
  @Test("Seeds commands, AI config, workspace state, and wrapper without overwriting user edits")
  func seedsDefaultsWithoutOverwritingUserEdits() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sierra_bootstrap_\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
    let repo = home.appendingPathComponent("sierra", isDirectory: true)
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent("conductor/workspaces/ticketmaster/run-1/.git", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    {
      "mcpServers": {
        "sierra-tools": {
          "type": "http",
          "url": "https://sierra.tools/-/api/mcp"
        }
      },
      "projects": {
        "\(home.path)/sierra": {
          "mcpServers": {
            "linear-server": {
              "type": "sse",
              "url": "https://mcp.linear.app/sse"
            }
          }
        }
      }
    }
    """.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

    let defaults = try #require(UserDefaults(suiteName: "SierraDefaultsBootstrapTests-\(UUID().uuidString)"))
    defaults.set("custom-claude", forKey: AgentHubDefaults.claudeCommand)
    let store = try SessionMetadataStore(path: root.appendingPathComponent("metadata.sqlite").path)

    let bootstrap = SierraDefaultsBootstrap(
      metadataStore: store,
      defaults: defaults,
      homeDirectory: home,
      applicationSupportDirectory: appSupport
    )
    await bootstrap.bootstrap()

    #expect(defaults.string(forKey: AgentHubDefaults.claudeCommand) == "custom-claude")
    #expect(defaults.string(forKey: AgentHubDefaults.codexCommand) == "codex")
    #expect(defaults.bool(forKey: AgentHubDefaults.enabledProviders + ".claude"))
    #expect(defaults.bool(forKey: AgentHubDefaults.enabledProviders + ".codex"))
    #expect(defaults.bool(forKey: AgentHubDefaults.sierraDefaultsBootstrapped))

    let claudeConfig = try #require(try await store.getAIConfig(for: "claude"))
    let codexConfig = try #require(try await store.getAIConfig(for: "codex"))
    #expect(claudeConfig.defaultModel == "us.anthropic.claude-opus-4-8[1m]")
    #expect(claudeConfig.effortLevel == "high")
    #expect(codexConfig.defaultModel == "gpt-5.5")
    #expect(codexConfig.effortLevel == "high")

    let claudeWorkspace = store.getWorkspaceStateSync(for: .claude)
    let codexWorkspace = store.getWorkspaceStateSync(for: .codex)
    #expect(claudeWorkspace.selectedRepositoryPaths == codexWorkspace.selectedRepositoryPaths)
    #expect(claudeWorkspace.selectedRepositoryPaths.contains(repo.path))
    #expect(claudeWorkspace.selectedRepositoryPaths.contains(
      home.appendingPathComponent("conductor/workspaces/ticketmaster/run-1").path
    ))

    let wrapperURL = appSupport.appendingPathComponent("bin/agenthub-claude")
    let settingsURL = appSupport.appendingPathComponent("claude-config/settings.json")
    let mcpConfigURL = appSupport.appendingPathComponent("claude-config/mcp-config.json")
    #expect(FileManager.default.isExecutableFile(atPath: wrapperURL.path))
    #expect(FileManager.default.fileExists(atPath: settingsURL.path))
    #expect(FileManager.default.fileExists(atPath: mcpConfigURL.path))
    let wrapperScript = try String(contentsOf: wrapperURL, encoding: .utf8)
    #expect(wrapperScript.contains("--mcp-config=\"\(mcpConfigURL.path)\""))
    let settingsData = try Data(contentsOf: settingsURL)
    let settings = try #require(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
    #expect(settings["enableAllProjectMcpServers"] as? Bool == true)
    let permissions = try #require(settings["permissions"] as? [String: Any])
    let allow = try #require(permissions["allow"] as? [String])
    #expect(allow.contains("mcp__sierra__*"))
    #expect(allow.contains("mcp__sierra-tools__*"))
    #expect(allow.contains("mcp__plugin_figma_figma__*"))
    #expect(!allow.contains("mcp__*"))
    let mcpConfigData = try Data(contentsOf: mcpConfigURL)
    let mcpConfig = try #require(JSONSerialization.jsonObject(with: mcpConfigData) as? [String: Any])
    let mcpServers = try #require(mcpConfig["mcpServers"] as? [String: Any])
    #expect(mcpServers["sierra-tools"] != nil)
    #expect(mcpServers["linear-server"] == nil)
  }

  @Test("Does not overwrite existing AI config or workspace state")
  func preservesExistingConfigAndWorkspaceState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sierra_bootstrap_preserve_\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent("sierra/.git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let store = try SessionMetadataStore(path: root.appendingPathComponent("metadata.sqlite").path)
    try await store.saveWorkspaceState(
      SessionWorkspaceState(selectedRepositoryPaths: ["/existing"]),
      for: .claude
    )
    try await store.saveAIConfig(AIConfigRecord(
      provider: "claude",
      defaultModel: "custom-model",
      effortLevel: "medium"
    ))

    let defaults = try #require(UserDefaults(suiteName: "SierraDefaultsBootstrapTests-\(UUID().uuidString)"))
    await SierraDefaultsBootstrap(
      metadataStore: store,
      defaults: defaults,
      homeDirectory: home,
      applicationSupportDirectory: root.appendingPathComponent("app-support", isDirectory: true)
    ).bootstrap()

    let claudeConfig = try #require(try await store.getAIConfig(for: "claude"))
    #expect(claudeConfig.defaultModel == "custom-model")
    #expect(claudeConfig.effortLevel == "medium")
    #expect(store.getWorkspaceStateSync(for: .claude).selectedRepositoryPaths == ["/existing"])
  }
}
