import Foundation
import Testing

@testable import AgentHubCore

@Suite("Managed process registry")
struct ManagedProcessRegistryTests {
  @Test("SQLite store saves and deletes managed process rows without touching session metadata")
  func sqliteStoreSavesAndDeletesManagedProcessRows() async throws {
    let store = try SessionMetadataStore(path: temporaryManagedProcessRegistryDatabasePath())
    try await store.setCustomName("Important session", for: "session-1")

    let record = managedProcessRegistryRow(pid: 101, kind: .agentTerminal, startTime: 10)
    try await store.saveManagedProcess(record)
    #expect(try await store.getManagedProcesses() == [record])

    try await store.deleteManagedProcess(pid: 101)
    #expect(try await store.getManagedProcesses().isEmpty)
    #expect(try await store.getCustomName(for: "session-1") == "Important session")
  }

  @Test("Registry cleanup terminates matching app-owned identities")
  func registryCleanupTerminatesMatchingIdentities() async throws {
    let store = RootMockManagedProcessStore(records: [
      managedProcessRegistryRow(pid: 111, kind: .agentTerminal, startTime: 10),
      managedProcessRegistryRow(pid: 222, kind: .devServer, startTime: 20)
    ])
    let terminator = RootMockProcessTerminator()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: RootMockProcessInspector(identities: [
        111: managedProcessIdentity(pid: 111, groupId: 111, startTime: 10),
        222: managedProcessIdentity(pid: 222, groupId: 222, startTime: 20)
      ]),
      processTerminator: terminator
    )

    await registry.cleanupRegisteredProcesses()

    #expect(await terminator.terminatedPIDs().sorted() == [111, 222])
    #expect(try await store.getManagedProcesses().isEmpty)
  }

  @Test("Registry cleanup prunes PID reuse without terminating")
  func registryCleanupPrunesPIDReuseWithoutTerminating() async throws {
    let store = RootMockManagedProcessStore(records: [
      managedProcessRegistryRow(pid: 111, kind: .agentTerminal, startTime: 10)
    ])
    let terminator = RootMockProcessTerminator()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: RootMockProcessInspector(identities: [
        111: managedProcessIdentity(pid: 111, groupId: 111, startTime: 99)
      ]),
      processTerminator: terminator
    )

    await registry.cleanupRegisteredProcesses()

    #expect(await terminator.terminatedPIDs().isEmpty)
    #expect(try await store.getManagedProcesses().isEmpty)
  }

  @Test("Alive terminal PID query excludes dev servers and prunes dead terminal rows")
  func aliveTerminalPIDQueryExcludesDevServersAndPrunesDeadRows() async throws {
    let store = RootMockManagedProcessStore(records: [
      managedProcessRegistryRow(pid: 111, kind: .agentTerminal, startTime: 10),
      managedProcessRegistryRow(pid: 222, kind: .auxiliaryShell, startTime: 20),
      managedProcessRegistryRow(pid: 333, kind: .devServer, startTime: 30),
      managedProcessRegistryRow(pid: 444, kind: .agentTerminal, startTime: 40)
    ])
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: RootMockProcessInspector(identities: [
        111: managedProcessIdentity(pid: 111, groupId: 111, startTime: 10),
        222: managedProcessIdentity(pid: 222, groupId: 222, startTime: 20),
        333: managedProcessIdentity(pid: 333, groupId: 333, startTime: 30)
      ]),
      processTerminator: RootMockProcessTerminator()
    )

    #expect(await registry.getAliveRegisteredPIDs() == Set<Int32>([111, 222]))
    #expect(try await store.getManagedProcesses().map(\.pid).sorted() == [111, 222, 333])
  }

  @Test("Legacy UserDefaults process registry data is ignored")
  func legacyUserDefaultsProcessRegistryDataIsIgnored() async throws {
    let legacyKey = "AgentHub.TerminalProcessRegistry"
    UserDefaults.standard.set(["111": 1_700_000_000.0], forKey: legacyKey)
    defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

    let store = RootMockManagedProcessStore()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: RootMockProcessInspector(identities: [
        111: managedProcessIdentity(pid: 111, groupId: 111, startTime: 10)
      ]),
      processTerminator: RootMockProcessTerminator()
    )

    #expect(await registry.getAliveRegisteredPIDs().isEmpty)
    #expect(try await store.getManagedProcesses().isEmpty)
  }
}

private actor RootMockManagedProcessStore: ManagedProcessStoreProtocol {
  private var records: [Int32: ManagedProcessRecord]

  init(records: [ManagedProcessRecord] = []) {
    self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
  }

  func saveManagedProcess(_ record: ManagedProcessRecord) async throws {
    records[record.pid] = record
  }

  func deleteManagedProcess(pid: Int32) async throws {
    records.removeValue(forKey: pid)
  }

  func deleteManagedProcesses(pids: [Int32]) async throws {
    for pid in pids {
      records.removeValue(forKey: pid)
    }
  }

  func getManagedProcesses() async throws -> [ManagedProcessRecord] {
    records.values.sorted { $0.pid < $1.pid }
  }
}

private actor RootMockProcessInspector: ProcessInspecting {
  private var identities: [pid_t: ManagedProcessIdentity]

  init(identities: [pid_t: ManagedProcessIdentity]) {
    self.identities = identities
  }

  func identity(for pid: pid_t) async -> ManagedProcessIdentity? {
    identities[pid]
  }
}

private actor RootMockProcessTerminator: ProcessTerminating {
  private var pids: [pid_t] = []

  func terminate(pid: pid_t, processGroupId: pid_t?) async {
    pids.append(pid)
  }

  func terminatedPIDs() -> [pid_t] {
    pids
  }
}

private func managedProcessIdentity(pid: pid_t, groupId: pid_t, startTime: Int64) -> ManagedProcessIdentity {
  ManagedProcessIdentity(
    pid: pid,
    processGroupId: groupId,
    startTimeSeconds: startTime,
    commandLine: nil
  )
}

private func managedProcessRegistryRow(
  pid: Int32,
  kind: ManagedProcessKind,
  startTime: Int64
) -> ManagedProcessRecord {
  ManagedProcessRecord(
    pid: pid,
    processGroupId: pid,
    processStartTimeSeconds: startTime,
    kind: kind,
    provider: nil,
    terminalKey: nil,
    sessionId: nil,
    projectPath: nil,
    expectedExecutable: nil,
    registeredAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2)
  )
}

private func temporaryManagedProcessRegistryDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_managed_process_registry_\(UUID().uuidString).sqlite")
    .path
}
