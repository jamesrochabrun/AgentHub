import Foundation
import Testing

@testable import AgentHubCore

@Suite("Managed process store")
struct ManagedProcessStoreTests {
  @Test("Saves updates and deletes managed process rows without touching metadata")
  func savesUpdatesAndDeletesManagedProcesses() async throws {
    let store = try SessionMetadataStore(path: temporaryManagedProcessDatabasePath())
    try await store.setCustomName("Important session", for: "session-1")

    let first = managedProcessRecord(
      pid: 101,
      kind: .agentTerminal,
      provider: SessionProviderKind.claude.rawValue,
      sessionId: "session-1",
      projectPath: "/tmp/project"
    )
    try await store.saveManagedProcess(first)

    var rows = try await store.getManagedProcesses()
    #expect(rows == [first])

    let updated = managedProcessRecord(
      pid: 101,
      kind: .devServer,
      provider: nil,
      terminalKey: "session-1:storybook",
      sessionId: nil,
      projectPath: "/tmp/project"
    )
    try await store.saveManagedProcess(updated)

    rows = try await store.getManagedProcesses()
    #expect(rows == [updated])

    try await store.deleteManagedProcess(pid: 101)
    #expect(try await store.getManagedProcesses().isEmpty)
    #expect(try await store.getCustomName(for: "session-1") == "Important session")
  }

  @Test("clearAll removes managed process rows")
  func clearAllRemovesManagedProcessRows() async throws {
    let store = try SessionMetadataStore(path: temporaryManagedProcessDatabasePath())
    try await store.saveManagedProcess(managedProcessRecord(pid: 202, kind: .auxiliaryShell))

    #expect(try await store.getManagedProcesses().count == 1)

    try await store.clearAll()
    #expect(try await store.getManagedProcesses().isEmpty)
  }
}

private func managedProcessRecord(
  pid: Int32,
  kind: ManagedProcessKind,
  provider: String? = nil,
  terminalKey: String? = "terminal-\(UUID().uuidString)",
  sessionId: String? = nil,
  projectPath: String? = nil
) -> ManagedProcessRecord {
  ManagedProcessRecord(
    pid: pid,
    processGroupId: pid,
    processStartTimeSeconds: 1_700_000_000 + Int64(pid),
    kind: kind,
    provider: provider,
    terminalKey: terminalKey,
    sessionId: sessionId,
    projectPath: projectPath,
    expectedExecutable: nil,
    registeredAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
  )
}

private func temporaryManagedProcessDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_managed_processes_\(UUID().uuidString).sqlite")
    .path
}
