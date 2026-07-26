import Foundation
import Testing

@testable import AgentHubCore

@Suite("AgentHubSessionNamingSkillCleanup")
struct AgentHubSessionNamingSkillCleanupTests {
  @Test("Removes the skill earlier builds installed for both providers")
  func removesInstalledSkillForBothProviders() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubSessionNamingSkillCleanupTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let claudeSkillDirectory = temporaryDirectory
      .appendingPathComponent(".claude/skills/agenthub-session-naming", isDirectory: true)
    let codexSkillDirectory = temporaryDirectory
      .appendingPathComponent(".agents/skills/agenthub-session-naming", isDirectory: true)
    let unrelatedSkillDirectory = temporaryDirectory
      .appendingPathComponent(".claude/skills/agenthub-task-manager", isDirectory: true)

    for directory in [claudeSkillDirectory, codexSkillDirectory, unrelatedSkillDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("---\n".utf8).write(to: directory.appendingPathComponent("SKILL.md", isDirectory: false))
    }

    AgentHubSessionNamingSkillCleanup.removeInstalledSkillBestEffort(homeDirectory: temporaryDirectory)

    #expect(!FileManager.default.fileExists(atPath: claudeSkillDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: codexSkillDirectory.path))
    // Other AgentHub skills must survive the sweep.
    #expect(FileManager.default.fileExists(atPath: unrelatedSkillDirectory.path))
  }

  @Test("Is a no-op when no skill is installed")
  func isNoOpWhenNothingInstalled() {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubSessionNamingSkillCleanupTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    AgentHubSessionNamingSkillCleanup.removeInstalledSkillBestEffort(homeDirectory: temporaryDirectory)

    #expect(!FileManager.default.fileExists(atPath: temporaryDirectory.path))
  }
}
