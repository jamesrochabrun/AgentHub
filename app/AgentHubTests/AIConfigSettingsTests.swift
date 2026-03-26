//
//  AIConfigSettingsTests.swift
//  AgentHub
//
//  Tests for AI configuration argument generation and persistence.
//

import Foundation
import Testing
@testable import AgentHubCore

// MARK: - Claude AI Config Argument Tests

@Suite("CLICommandConfiguration — Claude AI config flags")
struct ClaudeAIConfigArgumentTests {

  private let config = CLICommandConfiguration.claudeDefault

  @Test("Passes --model flag for new session")
  func modelFlagNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: nil, model: "opus"
    )
    let idx = args.firstIndex(of: "--model")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "opus")
  }

  @Test("Passes --effort flag for new session")
  func effortFlagNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: nil, effortLevel: "high"
    )
    let idx = args.firstIndex(of: "--effort")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "high")
  }

  @Test("Passes --allowedTools for new session")
  func allowedToolsNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: nil,
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
      sessionId: nil, prompt: nil,
      disallowedTools: ["Bash(rm -rf *)"]
    )
    let idx = args.firstIndex(of: "--disallowedTools")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "Bash(rm -rf *)")
  }

  @Test("No AI flags when all values are nil")
  func noFlagsWhenNil() {
    let args = config.argumentsForSession(sessionId: nil, prompt: nil)
    #expect(!args.contains("--model"))
    #expect(!args.contains("--effort"))
    #expect(!args.contains("--allowedTools"))
    #expect(!args.contains("--disallowedTools"))
  }

  @Test("No AI flags when values are empty strings")
  func noFlagsWhenEmpty() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: nil,
      model: "", effortLevel: "",
      allowedTools: [], disallowedTools: []
    )
    #expect(!args.contains("--model"))
    #expect(!args.contains("--effort"))
    #expect(!args.contains("--allowedTools"))
    #expect(!args.contains("--disallowedTools"))
  }

  @Test("Resume session does not get AI config flags")
  func resumeNoAIFlags() {
    let args = config.argumentsForSession(
      sessionId: "abc-123", prompt: nil,
      model: "opus", effortLevel: "high",
      allowedTools: ["Read"], disallowedTools: ["Bash(rm *)"]
    )
    #expect(!args.contains("--model"))
    #expect(!args.contains("--effort"))
    #expect(!args.contains("--allowedTools"))
    #expect(!args.contains("--disallowedTools"))
    #expect(args.contains("-r"))
    #expect(args.contains("abc-123"))
  }

  @Test("AI flags combined with existing flags")
  func combinedWithExistingFlags() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: "hello",
      dangerouslySkipPermissions: true,
      model: "sonnet", effortLevel: "medium"
    )
    #expect(args.contains("--dangerously-skip-permissions"))
    #expect(args.contains("--model"))
    #expect(args.contains("--effort"))
    #expect(args.last == "hello")
  }
}

// MARK: - Codex AI Config Argument Tests

@Suite("CLICommandConfiguration — Codex AI config flags")
struct CodexAIConfigArgumentTests {

  private let config = CLICommandConfiguration.codexDefault

  @Test("Passes --model flag for new Codex session")
  func modelFlagNewSession() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: nil, model: "gpt-5-codex"
    )
    let idx = args.firstIndex(of: "--model")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "gpt-5-codex")
  }

  @Test("Passes -c approval_policy for new Codex session")
  func approvalPolicyFlag() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: nil, codexApprovalPolicy: "suggest"
    )
    let idx = args.firstIndex(of: "-c")
    #expect(idx != nil)
    #expect(args[idx! + 1] == "approval_policy=suggest")
  }

  @Test("Passes -c model_reasoning_effort for new Codex session")
  func reasoningEffortFlag() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: nil, effortLevel: "high"
    )
    let cIdx = args.firstIndex(of: "-c")
    #expect(cIdx != nil)
    #expect(args[cIdx! + 1] == "model_reasoning_effort=high")
  }

  @Test("No AI flags for Codex resume")
  func resumeNoAIFlags() {
    let args = config.argumentsForSession(
      sessionId: "session-1", prompt: nil,
      model: "gpt-5-codex", codexApprovalPolicy: "full-auto"
    )
    #expect(!args.contains("--model"))
    #expect(!args.contains("-c"))
    #expect(args.contains("resume"))
    #expect(args.contains("session-1"))
  }

  @Test("No AI flags when all values nil")
  func noFlagsWhenNil() {
    let args = config.argumentsForSession(sessionId: nil, prompt: nil)
    #expect(!args.contains("--model"))
    #expect(!args.contains("-c"))
  }

  @Test("Codex AI flags with prompt")
  func aiConfigWithPrompt() {
    let args = config.argumentsForSession(
      sessionId: nil, prompt: "fix bugs",
      model: "gpt-5-codex", codexApprovalPolicy: "auto-edit"
    )
    #expect(args.contains("--model"))
    #expect(args.last == "fix bugs")
  }
}

// MARK: - AIConfigRecord Tool Pattern Parsing Tests

@Suite("AIConfigRecord.parseToolPatterns")
struct ParseToolPatternsTests {

  @Test("Parses comma-separated patterns")
  func commaDelimited() {
    let result = AIConfigRecord.parseToolPatterns("Bash(npm *), Read, Edit")
    #expect(result == ["Bash(npm *)", "Read", "Edit"])
  }

  @Test("Trims whitespace")
  func trimsWhitespace() {
    let result = AIConfigRecord.parseToolPatterns("  Bash(npm *)  ,  Read  ")
    #expect(result == ["Bash(npm *)", "Read"])
  }

  @Test("Returns empty for nil")
  func nilInput() {
    let result = AIConfigRecord.parseToolPatterns(nil)
    #expect(result.isEmpty)
  }

  @Test("Returns empty for empty string")
  func emptyString() {
    let result = AIConfigRecord.parseToolPatterns("")
    #expect(result.isEmpty)
  }

  @Test("Handles single pattern")
  func singlePattern() {
    let result = AIConfigRecord.parseToolPatterns("Read")
    #expect(result == ["Read"])
  }

  @Test("Ignores empty entries from trailing commas")
  func trailingComma() {
    let result = AIConfigRecord.parseToolPatterns("Read, Edit, ")
    #expect(result == ["Read", "Edit"])
  }
}

// MARK: - AIConfigService Persistence Tests

@Suite("AIConfigService round-trip persistence")
struct AIConfigServicePersistenceTests {

  @Test("Save and read Claude config")
  func claudeRoundTrip() async throws {
    let tempDir = FileManager.default.temporaryDirectory
    let dbPath = tempDir.appendingPathComponent("test_ai_config_\(UUID().uuidString).sqlite").path
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
    #expect(loaded != nil)
    #expect(loaded?.defaultModel == "opus")
    #expect(loaded?.effortLevel == "high")
    #expect(loaded?.allowedTools == "Bash(npm *), Read")
    #expect(loaded?.disallowedTools == "Bash(rm *)")

    try? FileManager.default.removeItem(atPath: dbPath)
  }

  @Test("Save and read Codex config")
  func codexRoundTrip() async throws {
    let tempDir = FileManager.default.temporaryDirectory
    let dbPath = tempDir.appendingPathComponent("test_ai_config_\(UUID().uuidString).sqlite").path
    let store = try SessionMetadataStore(path: dbPath)
    let service = AIConfigService(metadataStore: store)

    let record = AIConfigRecord(
      provider: "codex",
      defaultModel: "gpt-5-codex",
      effortLevel: "medium",
      approvalPolicy: "suggest"
    )
    try await service.saveConfig(record)

    let loaded = try await service.getConfig(for: "codex")
    #expect(loaded != nil)
    #expect(loaded?.defaultModel == "gpt-5-codex")
    #expect(loaded?.effortLevel == "medium")
    #expect(loaded?.approvalPolicy == "suggest")

    try? FileManager.default.removeItem(atPath: dbPath)
  }

  @Test("Update existing config")
  func updateExisting() async throws {
    let tempDir = FileManager.default.temporaryDirectory
    let dbPath = tempDir.appendingPathComponent("test_ai_config_\(UUID().uuidString).sqlite").path
    let store = try SessionMetadataStore(path: dbPath)
    let service = AIConfigService(metadataStore: store)

    var record = AIConfigRecord(provider: "claude", defaultModel: "sonnet")
    try await service.saveConfig(record)

    record.defaultModel = "opus"
    record.effortLevel = "high"
    try await service.saveConfig(record)

    let loaded = try await service.getConfig(for: "claude")
    #expect(loaded?.defaultModel == "opus")
    #expect(loaded?.effortLevel == "high")

    try? FileManager.default.removeItem(atPath: dbPath)
  }

  @Test("Returns nil for missing provider")
  func missingProvider() async throws {
    let tempDir = FileManager.default.temporaryDirectory
    let dbPath = tempDir.appendingPathComponent("test_ai_config_\(UUID().uuidString).sqlite").path
    let store = try SessionMetadataStore(path: dbPath)
    let service = AIConfigService(metadataStore: store)

    let loaded = try await service.getConfig(for: "claude")
    #expect(loaded == nil)

    try? FileManager.default.removeItem(atPath: dbPath)
  }

  @Test("Sync read works for AI config")
  func syncRead() async throws {
    let tempDir = FileManager.default.temporaryDirectory
    let dbPath = tempDir.appendingPathComponent("test_ai_config_\(UUID().uuidString).sqlite").path
    let store = try SessionMetadataStore(path: dbPath)

    let record = AIConfigRecord(provider: "claude", defaultModel: "opus")
    try await store.saveAIConfig(record)

    let loaded = store.getAIConfigSync(for: "claude")
    #expect(loaded != nil)
    #expect(loaded?.defaultModel == "opus")

    try? FileManager.default.removeItem(atPath: dbPath)
  }
}
