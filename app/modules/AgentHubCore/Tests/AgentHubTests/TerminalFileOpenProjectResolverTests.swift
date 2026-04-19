//
//  TerminalFileOpenProjectResolverTests.swift
//  AgentHubTests
//

import Foundation
import Testing

@testable import AgentHubCore

struct TerminalFileOpenProjectResolverTests {
  @Test func usesSessionProjectWhenFileIsInsideSessionProject() {
    let projectPath = "/tmp/AgentHubResolver/project"
    let filePath = projectPath + "/Sources/App.swift"

    let resolved = TerminalFileOpenProjectResolver.projectPath(
      forFile: filePath,
      sessionProjectPath: projectPath,
      repositories: []
    )

    #expect(resolved == projectPath)
  }

  @Test func usesSelectedWorktreeContainingExternalFile() {
    let sessionProjectPath = "/tmp/AgentHubResolver/Easel"
    let worktreePath = "/tmp/AgentHubResolver/agenthub-buenos-aires-692130"
    let filePath = worktreePath + "/app/modules/AgentHubCore/Sources/AgentHub/Intelligence/WorktreeOrchestrationTool.swift"
    let repositories = [
      SelectedRepository(
        path: "/tmp/AgentHubResolver/agenthub",
        worktrees: [
          WorktreeBranch(
            name: "agenthub-buenos-aires-692130",
            path: worktreePath,
            isWorktree: true
          )
        ]
      )
    ]

    let resolved = TerminalFileOpenProjectResolver.projectPath(
      forFile: filePath,
      sessionProjectPath: sessionProjectPath,
      repositories: repositories
    )

    #expect(resolved == worktreePath)
  }

  @Test func fallsBackToNearestGitRootForUntrackedProject() throws {
    let root = try makeTemporaryDirectory()
    let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
    let nestedDirectory = root.appendingPathComponent("Sources/App", isDirectory: true)
    let file = nestedDirectory.appendingPathComponent("Feature.swift")
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: file.path, contents: Data())

    let resolved = TerminalFileOpenProjectResolver.projectPath(
      forFile: file.path,
      sessionProjectPath: "/tmp/AgentHubResolver/Easel",
      repositories: []
    )

    #expect(resolved == root.path)
  }

  @Test func fallsBackToParentDirectoryWhenNoKnownRootContainsFile() throws {
    let root = try makeTemporaryDirectory()
    let file = root.appendingPathComponent("LooseFile.swift")
    FileManager.default.createFile(atPath: file.path, contents: Data())

    let resolved = TerminalFileOpenProjectResolver.projectPath(
      forFile: file.path,
      sessionProjectPath: "/tmp/AgentHubResolver/Easel",
      repositories: []
    )

    #expect(resolved == root.path)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubResolver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
