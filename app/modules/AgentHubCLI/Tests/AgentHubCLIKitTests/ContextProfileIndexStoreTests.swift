import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("ContextProfileIndexStore")
struct ContextProfileIndexStoreTests {
  @Test("An index round-trips with selection paths and instructions")
  func indexRoundTrips() throws {
    let directory = try temporaryIndexDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = ContextProfileIndexStore(directoryURL: directory)
    try store.write(makeIndex(projectPath: "/tmp/project"))

    let read = try #require(store.read(projectPath: "/tmp/project"))
    #expect(read.profiles.map(\.id) == ["profile-1"])
    #expect(read.profiles.first?.relativeFilePaths == ["CLAUDE.md", "Sources/App/Main.swift"])
    #expect(read.profiles.first?.isDefault == true)
    #expect(read.profiles.first?.scope == "project")
  }

  /// The CLI only knows `AGENTHUB_PROJECT_PATH`, which for a worktree session is
  /// the worktree — not the repo the profiles are filed under. Mirroring to
  /// aliases is what lets it find the list anyway.
  @Test("Aliases resolve a worktree path to the parent repo's index")
  func aliasesResolveWorktreePaths() throws {
    let directory = try temporaryIndexDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = ContextProfileIndexStore(directoryURL: directory)
    try store.write(
      makeIndex(projectPath: "/Users/me/code/app"),
      aliasPaths: ["/Users/me/code/app-feature"]
    )

    #expect(store.read(projectPath: "/Users/me/code/app-feature")?.profiles.count == 1)
    #expect(store.read(projectPath: "/Users/me/code/app-feature")?.projectPath == "/Users/me/code/app")
  }

  @Test("An unknown project reads back as nothing rather than failing")
  func unknownProjectReadsBackNil() throws {
    let directory = try temporaryIndexDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    #expect(ContextProfileIndexStore(directoryURL: directory).read(projectPath: "/tmp/nothing") == nil)
  }

  @Test("Rewriting replaces the previous index rather than appending")
  func rewritingReplaces() throws {
    let directory = try temporaryIndexDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = ContextProfileIndexStore(directoryURL: directory)
    try store.write(makeIndex(projectPath: "/tmp/project"))
    try store.write(ContextProfileIndex(projectPath: "/tmp/project", updatedAt: .now, profiles: []))

    #expect(store.read(projectPath: "/tmp/project")?.profiles.isEmpty == true)
  }

  /// Substituting separators (`/` → `-`) would make these two collide and
  /// silently merge two projects' profiles.
  @Test("Similar paths do not collide on disk")
  func similarPathsDoNotCollide() {
    let first = ContextProfileIndexStore.fileName(forProjectPath: "/a/b-c")
    let second = ContextProfileIndexStore.fileName(forProjectPath: "/a-b/c")
    #expect(first != second)
  }
}

private func makeIndex(projectPath: String) -> ContextProfileIndex {
  ContextProfileIndex(
    projectPath: projectPath,
    updatedAt: Date(timeIntervalSince1970: 5_000),
    profiles: [
      ContextProfileIndexEntry(
        id: "profile-1",
        name: "Voice work",
        scope: "project",
        isDefault: true,
        relativeFilePaths: ["CLAUDE.md", "Sources/App/Main.swift"],
        instructions: "Focus on the voice stack.",
        updatedAt: Date(timeIntervalSince1970: 4_000)
      )
    ]
  )
}

private func temporaryIndexDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-context-index-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("index", isDirectory: true)
}
