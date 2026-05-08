import Foundation
import Testing

@testable import AgentHubCore

@Suite("Claude hook install state store")
struct ClaudeHookInstallStateStoreTests {
  @Test("Loads empty installed paths")
  func loadsEmptyInstalledPaths() async throws {
    let store = try SessionMetadataStore(path: temporaryClaudeHookInstallStateDatabasePath())

    #expect(try await store.loadClaudeHookInstalledPaths().isEmpty)
  }

  @Test("Replaces installed paths")
  func replacesInstalledPaths() async throws {
    let store = try SessionMetadataStore(path: temporaryClaudeHookInstallStateDatabasePath())

    try await store.replaceClaudeHookInstalledPaths(["/tmp/project-a", "/tmp/project-b"])
    #expect(try await store.loadClaudeHookInstalledPaths() == Set(["/tmp/project-a", "/tmp/project-b"]))

    try await store.replaceClaudeHookInstalledPaths(["/tmp/project-b", "/tmp/project-c"])
    #expect(try await store.loadClaudeHookInstalledPaths() == Set(["/tmp/project-b", "/tmp/project-c"]))
  }

  @Test("Empty replacement clears installed paths")
  func emptyReplacementClearsInstalledPaths() async throws {
    let store = try SessionMetadataStore(path: temporaryClaudeHookInstallStateDatabasePath())

    try await store.replaceClaudeHookInstalledPaths(["/tmp/project-a"])
    try await store.replaceClaudeHookInstalledPaths([])

    #expect(try await store.loadClaudeHookInstalledPaths().isEmpty)
  }

  @Test("Installed paths persist across store instances")
  func installedPathsPersistAcrossStoreInstances() async throws {
    let dbPath = temporaryClaudeHookInstallStateDatabasePath()
    let firstStore = try SessionMetadataStore(path: dbPath)

    try await firstStore.replaceClaudeHookInstalledPaths(["/tmp/project-a", "/tmp/project-b"])

    let secondStore = try SessionMetadataStore(path: dbPath)
    #expect(try await secondStore.loadClaudeHookInstalledPaths() == Set(["/tmp/project-a", "/tmp/project-b"]))
  }
}

private func temporaryClaudeHookInstallStateDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_claude_hook_install_state_\(UUID().uuidString).sqlite")
    .path
}
