import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session workspace state persistence")
struct SessionWorkspaceStatePersistenceTests {

  @Test("Workspace state round-trips and is provider scoped")
  func workspaceStateRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryWorkspaceStateDatabasePath())
    let state = SessionWorkspaceState(
      selectedRepositoryPaths: ["/tmp/project-a", "/tmp/project-b"],
      monitoredSessionIds: ["session-1", "session-2"],
      expansionState: [
        "repo:/tmp/project-a": true,
        "wt:/tmp/project-a/worktrees/feature": false
      ]
    )

    try await store.saveWorkspaceState(state, for: .claude)

    #expect(store.getWorkspaceStateSync(for: .claude) == state)
    #expect(store.getWorkspaceStateSync(for: .codex) == SessionWorkspaceState())
  }

  @Test("Clear all removes workspace state")
  func clearAllRemovesWorkspaceState() async throws {
    let store = try SessionMetadataStore(path: temporaryWorkspaceStateDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1"],
        expansionState: ["repo:/tmp/project": true]
      ),
      for: .claude
    )

    try await store.clearAll()

    #expect(store.getWorkspaceStateSync(for: .claude) == SessionWorkspaceState())
  }
}

private func temporaryWorkspaceStateDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_workspace_state_\(UUID().uuidString).sqlite")
    .path
}
