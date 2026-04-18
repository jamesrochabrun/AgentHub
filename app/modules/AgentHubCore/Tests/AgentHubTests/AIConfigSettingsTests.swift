//
//  AIConfigSettingsTests.swift
//  AgentHub
//
//  Tests for AI configuration argument generation, persistence, and view-model loading.
//

import Foundation
import Testing
@testable import AgentHubCore

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

  @Test("Passes full-auto flag for Codex")
  func fullAutoFlag() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      codexApprovalPolicy: "full-auto"
    )

    #expect(args.contains("--full-auto"))
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

    try await store.clearAll()

    #expect(try await store.getCustomName(for: "session-1") == nil)
    #expect(try await store.getRepoMapping(for: "session-1") == nil)
    #expect(try await store.getAIConfig(for: "claude") == nil)
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
