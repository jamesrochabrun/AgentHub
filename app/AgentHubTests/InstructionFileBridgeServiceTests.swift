import Foundation
import Testing

@testable import AgentHubCore

// MARK: - bridgeDirectories Tests

@Suite("InstructionFileBridgeService.bridgeDirectories")
struct BridgeDirectoriesTests {

  @Test("Creates AGENTS.md symlink when only CLAUDE.md exists")
  func createsAgentsSymlinkFromClaude() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])

    let agentsPath = fixture.repoPath + "/AGENTS.md"
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: agentsPath)
    #expect(dest == "CLAUDE.md")
  }

  @Test("Creates CLAUDE.md symlink when only AGENTS.md exists")
  func createsClaudeSymlinkFromAgents() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/AGENTS.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])

    let claudePath = fixture.repoPath + "/CLAUDE.md"
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: claudePath)
    #expect(dest == "AGENTS.md")
  }

  @Test("Creates no symlinks when both files exist")
  func noSymlinksWhenBothExist() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Claude".write(toFile: fixture.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)
    try "# Agents".write(toFile: fixture.repoPath + "/AGENTS.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])

    // Neither should be a symlink
    let claudeIsSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.repoPath + "/CLAUDE.md")) != nil
    let agentsIsSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.repoPath + "/AGENTS.md")) != nil
    #expect(!claudeIsSymlink)
    #expect(!agentsIsSymlink)
  }

  @Test("Creates no symlinks when neither file exists")
  func noSymlinksWhenNeitherExists() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])

    #expect(!FileManager.default.fileExists(atPath: fixture.repoPath + "/CLAUDE.md"))
    #expect(!FileManager.default.fileExists(atPath: fixture.repoPath + "/AGENTS.md"))
  }

  @Test("Is idempotent — scanning the same directory twice creates only one symlink")
  func idempotentOnRescan() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])
    await service.bridgeDirectories([fixture.repoPath])

    // AGENTS.md should still be a valid symlink to CLAUDE.md (not broken)
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.repoPath + "/AGENTS.md")
    #expect(dest == "CLAUDE.md")
  }

  @Test("Bridges multiple directories in one call")
  func bridgesMultipleDirectories() async throws {
    let fixture1 = try GitRepoFixture.create()
    let fixture2 = try GitRepoFixture.create()
    defer {
      fixture1.cleanup()
      fixture2.cleanup()
    }

    try "# Instructions".write(toFile: fixture1.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)
    try "# Instructions".write(toFile: fixture2.repoPath + "/AGENTS.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture1.repoPath, fixture2.repoPath])

    let dest1 = try FileManager.default.destinationOfSymbolicLink(atPath: fixture1.repoPath + "/AGENTS.md")
    #expect(dest1 == "CLAUDE.md")

    let dest2 = try FileManager.default.destinationOfSymbolicLink(atPath: fixture2.repoPath + "/CLAUDE.md")
    #expect(dest2 == "AGENTS.md")
  }
}

// MARK: - cleanupAll Tests

@Suite("InstructionFileBridgeService.cleanupAll")
struct CleanupAllTests {

  @Test("Removes all created symlinks")
  func removesAllSymlinks() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])

    let agentsPath = fixture.repoPath + "/AGENTS.md"
    #expect(FileManager.default.fileExists(atPath: agentsPath))

    await service.cleanupAll()

    #expect(!FileManager.default.fileExists(atPath: agentsPath))
  }

  @Test("Is safe to call when no symlinks were created")
  func safeWhenNothingToClean() async {
    let service = InstructionFileBridgeService()
    // Should not throw or crash
    await service.cleanupAll()
  }

  @Test("Allows re-bridging after cleanup")
  func allowsRebridgingAfterCleanup() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])
    await service.cleanupAll()

    // After cleanup the directory is no longer tracked as scanned,
    // so bridging it again should recreate the symlink.
    await service.bridgeDirectories([fixture.repoPath])

    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.repoPath + "/AGENTS.md")
    #expect(dest == "CLAUDE.md")
  }
}

// MARK: - removeBridges Tests

@Suite("InstructionFileBridgeService.removeBridges")
struct RemoveBridgesTests {

  @Test("Removes symlinks only for the specified directory")
  func removesOnlyTargetDirectory() async throws {
    let fixture1 = try GitRepoFixture.create()
    let fixture2 = try GitRepoFixture.create()
    defer {
      fixture1.cleanup()
      fixture2.cleanup()
    }

    try "# Instructions".write(toFile: fixture1.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)
    try "# Instructions".write(toFile: fixture2.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture1.repoPath, fixture2.repoPath])

    await service.removeBridges(for: fixture1.repoPath)

    // fixture1's symlink should be gone
    #expect(!FileManager.default.fileExists(atPath: fixture1.repoPath + "/AGENTS.md"))

    // fixture2's symlink should still exist
    let dest2 = try FileManager.default.destinationOfSymbolicLink(atPath: fixture2.repoPath + "/AGENTS.md")
    #expect(dest2 == "CLAUDE.md")
  }

  @Test("Allows re-bridging the directory after its bridges are removed")
  func allowsRebridgingAfterRemoval() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])
    await service.removeBridges(for: fixture.repoPath)

    // Directory is no longer tracked, bridging again should work
    await service.bridgeDirectories([fixture.repoPath])

    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.repoPath + "/AGENTS.md")
    #expect(dest == "CLAUDE.md")
  }
}

// MARK: - Git Exclude Tests

@Suite("InstructionFileBridgeService git exclude registration")
struct GitExcludeTests {

  @Test("Writes symlink name to .git/info/exclude")
  func writesGitExclude() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])

    let excludePath = fixture.repoPath + "/.git/info/exclude"
    let contents = try String(contentsOfFile: excludePath, encoding: .utf8)
    #expect(contents.contains("/AGENTS.md"))
  }

  @Test("Does not duplicate entry on rescan")
  func doesNotDuplicateGitExcludeEntry() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    // Bridge once, cleanup, bridge again to force a second registerGitExclude call
    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])
    await service.cleanupAll()
    await service.bridgeDirectories([fixture.repoPath])

    let excludePath = fixture.repoPath + "/.git/info/exclude"
    let contents = try String(contentsOfFile: excludePath, encoding: .utf8)
    let occurrences = contents.components(separatedBy: "/AGENTS.md").count - 1
    #expect(occurrences == 1)
  }

  @Test("Writes CLAUDE.md to exclude when AGENTS.md is the source")
  func writesClaudeExcludeWhenAgentsIsSource() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "# Instructions".write(toFile: fixture.repoPath + "/AGENTS.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([fixture.repoPath])

    let excludePath = fixture.repoPath + "/.git/info/exclude"
    let contents = try String(contentsOfFile: excludePath, encoding: .utf8)
    #expect(contents.contains("/CLAUDE.md"))
  }

  @Test("Worktree symlink registers exclude in main repo's .git/info/exclude")
  func worktreeExcludeInMainRepo() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addWorktree(branch: "feature")
    try "# Instructions".write(toFile: worktreePath + "/CLAUDE.md", atomically: true, encoding: .utf8)

    let service = InstructionFileBridgeService()
    await service.bridgeDirectories([worktreePath])

    // Symlink should exist in the worktree
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: worktreePath + "/AGENTS.md")
    #expect(dest == "CLAUDE.md")

    // Exclude should be written to the main repo's .git/info/exclude
    let excludePath = fixture.repoPath + "/.git/info/exclude"
    let contents = try String(contentsOfFile: excludePath, encoding: .utf8)
    #expect(contents.contains("/AGENTS.md"))
  }
}
