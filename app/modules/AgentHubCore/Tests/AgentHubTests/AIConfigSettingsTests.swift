//
//  AIConfigSettingsTests.swift
//  AgentHub
//
//  Tests for AI configuration argument generation, persistence, and view-model loading.
//

import Foundation
import Testing
@testable import AgentHubCore

@Suite("CLICommandConfiguration — command and extra argument handling")
struct CLICommandConfigurationArgumentHandlingTests {

  @Test("Parses quoted command argument strings")
  func parsesQuotedArgumentStrings() {
    let args = CLICommandConfiguration.parseArgumentString("--api-mode enterprise --as-user 'Jane Doe' \"two words\"")

    #expect(args == ["--api-mode", "enterprise", "--as-user", "Jane Doe", "two words"])
  }

  @Test("Parses empty quoted command arguments")
  func parsesEmptyQuotedArgumentStrings() {
    let args = CLICommandConfiguration.parseArgumentString("--name '' --label \"\"")

    #expect(args == ["--name", "", "--label", ""])
  }

  @Test("AgentHub Claude wrapper passes wrapper args before Claude direct args")
  func agentHubClaudeWrapperUsesDirectArgumentSeparator() {
    let config = CLICommandConfiguration(
      command: "agenthub",
      mode: .claude,
      extraArgs: ["--api-mode", "enterprise"]
    )

    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: "Start work",
      agentHubMCPServerPath: "/Applications/AgentHub.app/Contents/Helpers/agenthub"
    )

    #expect(Array(args.prefix(4)) == ["claude", "--api-mode", "enterprise", "--"])

    guard let separatorIndex = args.firstIndex(of: "--"),
          let mcpConfigIndex = args.firstIndex(of: "--mcp-config") else {
      Issue.record("Expected AgentHub direct-argument separator and Claude MCP flag")
      return
    }

    #expect(mcpConfigIndex > separatorIndex)
    #expect(args.last == "Start work")
  }

  @Test("AgentHub Claude command does not duplicate explicit provider subcommand")
  func agentHubClaudeWrapperDoesNotDuplicateExplicitSubcommand() {
    let config = CLICommandConfiguration(
      command: "agenthub claude",
      mode: .claude,
      extraArgs: ["--api-mode", "enterprise"]
    )

    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      agentHubMCPServerPath: "/Applications/AgentHub.app/Contents/Helpers/agenthub"
    )

    #expect(args.first == "claude")
    #expect(args.filter { $0 == "claude" }.count == 1)
    #expect(args.prefix(4).contains("--api-mode"))
  }

  @Test("AgentHub Codex wrapper passes Codex config overrides after separator")
  func agentHubCodexWrapperUsesDirectArgumentSeparator() {
    let config = CLICommandConfiguration(
      command: "agenthub codex",
      mode: .codex,
      extraArgs: ["--no-banner"]
    )

    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: "Start work",
      agentHubMCPServerPath: "/Applications/AgentHub.app/Contents/Helpers/agenthub",
      effortLevel: "high"
    )

    #expect(Array(args.prefix(3)) == ["codex", "--no-banner", "--"])

    guard let separatorIndex = args.firstIndex(of: "--"),
          let configIndex = args.firstIndex(of: "-c") else {
      Issue.record("Expected AgentHub direct-argument separator and Codex config flag")
      return
    }

    #expect(configIndex > separatorIndex)
    #expect(args.last == "Start work")
  }

  @Test("Direct CLI keeps extra args before prompt")
  func directCLIKeepsExtraArgsBeforePrompt() {
    let config = CLICommandConfiguration(
      command: "claude",
      mode: .claude,
      extraArgs: ["--debug"]
    )

    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: "Start work"
    )

    #expect(Array(args.suffix(2)) == ["--debug", "Start work"])
  }

  @Test("Decodes previous CLI configuration payloads without extra args")
  func decodesLegacyConfigurationWithoutExtraArgs() throws {
    let data = Data("""
    {
      "command": "agenthub claude",
      "additionalPaths": [],
      "mode": "claude"
    }
    """.utf8)

    let config = try JSONDecoder().decode(CLICommandConfiguration.self, from: data)

    #expect(config.extraArgs.isEmpty)
  }
}

@Suite("CLICommandConfiguration — Claude AI config flags")
struct ClaudeAIConfigArgumentTests {

  private let config = CLICommandConfiguration.claudeDefault

  @Test("Passes --model flag for new session")
  func modelFlagNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      model: "opus"
    )

    let idx = args.firstIndex(of: "--model")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "opus")
  }

  @Test("Passes --effort flag for new session")
  func effortFlagNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      effortLevel: "high"
    )

    let idx = args.firstIndex(of: "--effort")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "high")
  }

  @Test("Passes --allowedTools for new session")
  func allowedToolsNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      allowedTools: ["Bash(npm *)", "Read"]
    )

    let idx = args.firstIndex(of: "--allowedTools")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "Bash(npm *)")
    #expect(args[idx! + 2] == "Read")
  }

  @Test("Passes --disallowedTools for new session")
  func disallowedToolsNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      disallowedTools: ["Bash(rm -rf *)"]
    )

    let idx = args.firstIndex(of: "--disallowedTools")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "Bash(rm -rf *)")
  }

  @Test("Resume session does not get AI config flags")
  func resumeNoAIFlags() {
    let args = config.argumentsForSession(
      sessionId: "abc-123",
      prompt: nil,
      model: "opus",
      effortLevel: "high",
      allowedTools: ["Read"],
      disallowedTools: ["Bash(rm *)"]
    )

    #expect(!args.contains("--model"))
    #expect(!args.contains("--effort"))
    #expect(!args.contains("--allowedTools"))
    #expect(!args.contains("--disallowedTools"))
    #expect(args.contains("-r"))
    #expect(args.contains("abc-123"))
  }
}

@Suite("CLICommandConfiguration — Codex AI config flags")
struct CodexAIConfigArgumentTests {

  private let config = CLICommandConfiguration.codexDefault

  @Test("Passes model flag for new Codex session")
  func modelFlagNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      model: "gpt-5-codex"
    )

    let idx = args.firstIndex(of: "--model")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "gpt-5-codex")
  }

  @Test("Passes approval flag for supported Codex policy")
  func approvalPolicyFlag() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      codexApprovalPolicy: "on-request"
    )

    let idx = args.firstIndex(of: "-a")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "on-request")
  }

  @Test("Maps Codex full-auto setting to workspace-write sandbox")
  func fullAutoFlag() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      codexApprovalPolicy: "full-auto"
    )

    let sandboxIdx = args.firstIndex(of: "--sandbox")
    #expect(sandboxIdx != nil)
    #expect(args[sandboxIdx! + 1] == "workspace-write")
    #expect(!args.contains("--full-auto"))
    #expect(!args.contains("-a"))
  }

  @Test("Ignores unsupported Codex approval values")
  func unsupportedApprovalPolicyIgnored() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      codexApprovalPolicy: "suggest"
    )

    #expect(!args.contains("-a"))
    #expect(!args.contains("--full-auto"))
    #expect(!args.contains("--sandbox"))
  }

  @Test("Passes reasoning effort via config override for new Codex session")
  func reasoningEffortFlag() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      effortLevel: "high"
    )

    let cIdx = args.firstIndex(of: "-c")
    #expect(cIdx != nil)
    #expect(args[cIdx! + 1] == "model_reasoning_effort=\"high\"")
  }

  @Test("Passes xhigh reasoning effort via config override for new Codex session")
  func xhighReasoningEffortFlag() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      effortLevel: "xhigh"
    )

    let cIdx = args.firstIndex(of: "-c")
    #expect(cIdx != nil)
    #expect(args[cIdx! + 1] == "model_reasoning_effort=\"xhigh\"")
  }

  @Test("No AI flags for Codex resume")
  func resumeNoAIFlags() {
    let args = config.argumentsForSession(
      sessionId: "session-1",
      prompt: nil,
      model: "gpt-5-codex",
      codexApprovalPolicy: "full-auto"
    )

    #expect(!args.contains("--model"))
    #expect(!args.contains("-a"))
    #expect(!args.contains("--full-auto"))
    #expect(!args.contains("--sandbox"))
    #expect(args.contains("resume"))
    #expect(args.contains("session-1"))
  }
}

@Suite("AIConfigRecord.parseToolPatterns")
struct ParseToolPatternsTests {

  @Test("Parses comma-separated patterns")
  func commaDelimited() {
    let result = AIConfigRecord.parseToolPatterns("Bash(npm *), Read, Edit")
    #expect(result == ["Bash(npm *)", "Read", "Edit"])
  }

  @Test("Parses newline-separated patterns")
  func newlineDelimited() {
    let result = AIConfigRecord.parseToolPatterns("Bash(npm *)\nRead\nEdit")
    #expect(result == ["Bash(npm *)", "Read", "Edit"])
  }

  @Test("Parses mixed comma and newline-separated patterns")
  func mixedDelimited() {
    let result = AIConfigRecord.parseToolPatterns("Bash(npm *), Read\nEdit")
    #expect(result == ["Bash(npm *)", "Read", "Edit"])
  }

  @Test("Returns empty for nil and blank strings")
  func emptyInputs() {
    #expect(AIConfigRecord.parseToolPatterns(nil).isEmpty)
    #expect(AIConfigRecord.parseToolPatterns("").isEmpty)
  }
}

@Suite("AIConfigService round-trip persistence")
struct AIConfigServicePersistenceTests {

  @Test("Save and read Claude config")
  func claudeRoundTrip() async throws {
    let dbPath = temporaryDatabasePath()
    let store = try SessionMetadataStore(path: dbPath)
    let service = AIConfigService(metadataStore: store)

    let record = AIConfigRecord(
      provider: "claude",
      defaultModel: "opus",
      effortLevel: "high",
      allowedTools: "Bash(npm *), Read",
      disallowedTools: "Bash(rm *)"
    )
    try await service.saveConfig(record)

    let loaded = try await service.getConfig(for: "claude")
    #expect(loaded?.defaultModel == "opus")
    #expect(loaded?.effortLevel == "high")
    #expect(loaded?.allowedTools == "Bash(npm *), Read")
    #expect(loaded?.disallowedTools == "Bash(rm *)")
  }

  @Test("Clear all removes AI config and repo mappings")
  func clearAllRemovesEveryMetadataTable() async throws {
    let dbPath = temporaryDatabasePath()
    let store = try SessionMetadataStore(path: dbPath)

    try await store.setCustomName("Demo", for: "session-1")
    try await store.setRepoMapping(
      SessionRepoMapping(
        sessionId: "session-1",
        parentRepoPath: "/tmp/repo",
        worktreePath: "/tmp/repo/.worktree/demo"
      )
    )
    try await store.saveAIConfig(
      AIConfigRecord(provider: "claude", defaultModel: "opus")
    )
    try await store.saveTerminalWorkspace(
      TerminalWorkspaceSnapshot(
        panels: [
          TerminalWorkspacePanelSnapshot(
            role: .primary,
            tabs: [TerminalWorkspaceTabSnapshot(role: .agent)]
          )
        ]
      ),
      provider: .claude,
      sessionId: "session-1",
      backend: .ghostty
    )

    try await store.clearAll()

    #expect(try await store.getCustomName(for: "session-1") == nil)
    #expect(try await store.getRepoMapping(for: "session-1") == nil)
    #expect(try await store.getAIConfig(for: "claude") == nil)
    #expect(store.loadTerminalWorkspace(provider: .claude, sessionId: "session-1", backend: .ghostty) == nil)
  }

  @Test("Pinned session IDs round-trip through async and sync reads")
  func pinnedSessionRoundTrip() async throws {
    let dbPath = temporaryDatabasePath()
    let store = try SessionMetadataStore(path: dbPath)

    try await store.setPinned(true, for: "session-1")

    #expect(try await store.getPinnedSessionIds() == Set(["session-1"]))
    #expect(store.getPinnedSessionIdsSync() == Set(["session-1"]))

    try await store.setPinned(false, for: "session-1")

    #expect(try await store.getPinnedSessionIds().isEmpty)
    #expect(store.getPinnedSessionIdsSync().isEmpty)
  }

  @Test("Terminal workspace snapshots are scoped by provider session and backend")
  func terminalWorkspaceRoundTrip() async throws {
    let dbPath = temporaryDatabasePath()
    let store = try SessionMetadataStore(path: dbPath)
    let snapshot = TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .agent,
              name: "Agent",
              title: "Claude",
              workingDirectory: "/tmp/project"
            ),
            TerminalWorkspaceTabSnapshot(
              role: .shell,
              name: "Shell",
              title: "zsh",
              workingDirectory: "/tmp/project"
            )
          ],
          activeTabIndex: 1
        )
      ]
    )

    try await store.saveTerminalWorkspace(
      snapshot,
      provider: .claude,
      sessionId: "session-1",
      backend: .ghostty
    )

    #expect(store.loadTerminalWorkspace(provider: .claude, sessionId: "session-1", backend: .ghostty) == snapshot)
    #expect(store.loadTerminalWorkspace(provider: .codex, sessionId: "session-1", backend: .ghostty) == nil)
    #expect(store.loadTerminalWorkspace(provider: .claude, sessionId: "session-1", backend: .regular) == nil)

    try await store.deleteTerminalWorkspace(provider: .claude, sessionId: "session-1", backend: .ghostty)

    #expect(store.loadTerminalWorkspace(provider: .claude, sessionId: "session-1", backend: .ghostty) == nil)
  }
}

@Suite("AIConfigSettingsViewModel")
struct AIConfigSettingsViewModelTests {

  @Test("Loads provider defaults through the service protocol")
  @MainActor
  func loadPopulatesFields() async {
    let service = MockAIConfigService(
      configs: [
        "claude": AIConfigRecord(
          provider: "claude",
          defaultModel: "opus",
          effortLevel: "high",
          allowedTools: "Read",
          disallowedTools: "Bash(rm *)"
        ),
        "codex": AIConfigRecord(
          provider: "codex",
          defaultModel: "gpt-5-codex",
          effortLevel: "medium",
          approvalPolicy: "on-request"
        )
      ]
    )
    let viewModel = AIConfigSettingsViewModel()

    await viewModel.load(service: service)

    #expect(viewModel.claudeModel == "opus")
    #expect(viewModel.claudeEffort == "high")
    #expect(viewModel.claudeAllowedTools == "Read")
    #expect(viewModel.claudeDisallowedTools == "Bash(rm *)")
    #expect(viewModel.codexModel == "gpt-5-codex")
    #expect(viewModel.codexReasoningEffort == "medium")
    #expect(viewModel.codexApprovalPolicy == "on-request")
  }

  @Test("Unsupported saved Codex approval policies fall back to default")
  @MainActor
  func invalidStoredApprovalPolicyFallsBack() async {
    let service = MockAIConfigService(
      configs: [
        "codex": AIConfigRecord(
          provider: "codex",
          defaultModel: "gpt-5-codex",
          effortLevel: "medium",
          approvalPolicy: "suggest"
        )
      ]
    )
    let viewModel = AIConfigSettingsViewModel()

    await viewModel.load(service: service)

    #expect(viewModel.codexApprovalPolicy.isEmpty)
  }

  @Test("Codex approval policy descriptions explain each launch mode")
  @MainActor
  func codexApprovalPolicyDescriptions() {
    let viewModel = AIConfigSettingsViewModel()

    viewModel.codexApprovalPolicy = ""
    #expect(viewModel.codexApprovalPolicyDescription.contains("CLI defaults"))

    viewModel.codexApprovalPolicy = "untrusted"
    #expect(viewModel.codexApprovalPolicyDescription.contains("trusted commands"))

    viewModel.codexApprovalPolicy = "on-request"
    #expect(viewModel.codexApprovalPolicyDescription.contains("Codex decides"))

    viewModel.codexApprovalPolicy = "never"
    #expect(viewModel.codexApprovalPolicyDescription.contains("never asks"))

    viewModel.codexApprovalPolicy = "full-auto"
    #expect(viewModel.codexApprovalPolicyDescription.contains("workspace-write sandbox"))
    #expect(viewModel.codexApprovalPolicyDescription.contains("not Full Access"))

    viewModel.codexApprovalPolicy = "suggest"
    #expect(viewModel.codexApprovalPolicyDescription.contains("CLI defaults"))
  }

  @Test("Refreshing models populates the picker options from the catalogs")
  @MainActor
  func refreshModelsPopulatesOptions() async {
    let viewModel = AIConfigSettingsViewModel(
      claudeModelCatalog: StubClaudeCatalog(options: [
        AIModelOption(identifier: "opus", displayName: "Opus"),
        AIModelOption(identifier: "claude-opus-4-8", displayName: "claude-opus-4-8"),
      ]),
      codexModelCatalog: StubCodexCatalog(options: [
        AIModelOption(identifier: "gpt-5.5", displayName: "GPT-5.5"),
      ])
    )

    await viewModel.refreshClaudeModels()
    await viewModel.refreshCodexModels()

    #expect(viewModel.claudeModels.map(\.identifier) == ["opus", "claude-opus-4-8"])
    #expect(viewModel.codexModels.map(\.identifier) == ["gpt-5.5"])
  }

  @Test("Codex effort options follow the selected model's reasoning levels")
  @MainActor
  func codexEffortOptionsFollowSelectedModel() async {
    let viewModel = AIConfigSettingsViewModel(
      claudeModelCatalog: StubClaudeCatalog(options: []),
      codexModelCatalog: StubCodexCatalog(options: [
        AIModelOption(
          identifier: "gpt-5.3-codex-spark",
          displayName: "GPT-5.3-Codex-Spark",
          reasoningEfforts: [
            AIReasoningEffort(effort: "low", description: "Fast"),
            AIReasoningEffort(effort: "high", description: "Deep"),
          ],
          defaultReasoningEffort: "high"
        )
      ])
    )

    await viewModel.refreshCodexModels()
    viewModel.codexModel = "gpt-5.3-codex-spark"

    #expect(viewModel.codexEffortOptions.map(\.effort) == ["low", "high"])
    #expect(viewModel.codexDefaultEffortHint == "high")

    viewModel.codexReasoningEffort = "high"
    #expect(viewModel.codexSelectedEffortDescription == "Deep")
  }

  @Test("Codex effort options fall back to the standard set for unknown models")
  @MainActor
  func codexEffortOptionsFallBack() {
    let viewModel = AIConfigSettingsViewModel(
      claudeModelCatalog: StubClaudeCatalog(options: []),
      codexModelCatalog: StubCodexCatalog(options: [])
    )

    #expect(viewModel.codexEffortOptions.map(\.effort) == ["low", "medium", "high", "xhigh"])
    #expect(viewModel.codexDefaultEffortHint == nil)
  }
}

private struct StubClaudeCatalog: ClaudeModelCatalogProviding {
  let options: [AIModelOption]
  func availableModels() async -> [AIModelOption] { options }
}

private struct StubCodexCatalog: CodexModelCatalogProviding {
  let options: [AIModelOption]
  func availableModels() async -> [AIModelOption] { options }
  func defaultModelIdentifier() async -> String { options.first?.identifier ?? "" }
}

private actor MockAIConfigService: AIConfigServiceProtocol {
  private let configs: [String: AIConfigRecord]

  init(configs: [String: AIConfigRecord]) {
    self.configs = configs
  }

  func getConfig(for provider: String) async throws -> AIConfigRecord? {
    configs[provider]
  }

  func saveConfig(_ record: AIConfigRecord) async throws {}
}

private func temporaryDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("test_ai_config_\(UUID().uuidString).sqlite")
    .path
}
