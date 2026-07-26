import Foundation
import Testing

@testable import AgentHubCore

@Suite("AgentHubSessionNamingSkillInstaller")
struct AgentHubSessionNamingSkillInstallerTests {
  @Test("Writes Claude and Codex skill files")
  func writesSkillFiles() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubSessionNamingSkillInstallerTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let skillMarkdown = """
    ---
    name: agenthub-session-naming
    ---
    """
    let openAIYAML = """
    policy:
      allow_implicit_invocation: true
    """

    try AgentHubSessionNamingSkillInstaller.installForAllProviders(
      homeDirectory: temporaryDirectory,
      skillMarkdown: skillMarkdown,
      openAIYAML: openAIYAML
    )

    let claudeSkillURL = temporaryDirectory
      .appendingPathComponent(".claude/skills/agenthub-session-naming/SKILL.md")
    let codexSkillURL = temporaryDirectory
      .appendingPathComponent(".agents/skills/agenthub-session-naming/SKILL.md")
    let codexMetadataURL = temporaryDirectory
      .appendingPathComponent(".agents/skills/agenthub-session-naming/agents/openai.yaml")

    #expect(try String(contentsOf: claudeSkillURL, encoding: .utf8) == skillMarkdown)
    #expect(try String(contentsOf: codexSkillURL, encoding: .utf8) == skillMarkdown)
    #expect(try String(contentsOf: codexMetadataURL, encoding: .utf8) == openAIYAML)
  }

  @Test("Bundled skill allows implicit invocation and requires final tool call")
  func bundledSkillHasFastRoutingContract() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubBundledSessionNamingSkillTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    try AgentHubSessionNamingSkillInstaller.installBundledSkillForAllProviders(
      homeDirectory: temporaryDirectory
    )

    let skill = try String(
      contentsOf: temporaryDirectory
        .appendingPathComponent(".agents/skills/agenthub-session-naming/SKILL.md"),
      encoding: .utf8
    )
    let metadata = try String(
      contentsOf: temporaryDirectory
        .appendingPathComponent(".agents/skills/agenthub-session-naming/agents/openai.yaml"),
      encoding: .utf8
    )

    #expect(skill.contains("at most the first three user messages"))
    #expect(skill.contains("mcp__agenthub__name_session"))
    #expect(skill.contains("immediately call `name_session` again"))
    #expect(metadata.contains("allow_implicit_invocation: true"))
    #expect(metadata.contains("value: \"agenthub\""))
  }
}
