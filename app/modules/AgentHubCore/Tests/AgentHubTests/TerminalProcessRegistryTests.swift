import Foundation
import Testing

@testable import AgentHubCore

@Suite("Terminal process registry")
struct TerminalProcessRegistryTests {
  @Test("Register persists process identity and metadata")
  func registerPersistsProcessIdentityAndMetadata() async throws {
    let store = MockManagedProcessStore()
    let inspector = MockProcessInspector(identities: [
      123: identity(pid: 123, groupId: 123, startTime: 1_000)
    ])
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: inspector,
      processTerminator: MockProcessTerminator()
    )
    let registeredAt = Date(timeIntervalSince1970: 42)

    await registry.register(
      pid: 123,
      kind: .agentTerminal,
      provider: .claude,
      terminalKey: "session-1",
      sessionId: "session-1",
      projectPath: "/tmp/project",
      expectedExecutable: "claude",
      requestedAt: registeredAt
    )

    let rows = try await store.getManagedProcesses()
    #expect(rows.count == 1)
    #expect(rows.first?.pid == 123)
    #expect(rows.first?.processGroupId == 123)
    #expect(rows.first?.processStartTimeSeconds == 1_000)
    #expect(rows.first?.processKind == .agentTerminal)
    #expect(rows.first?.provider == SessionProviderKind.claude.rawValue)
    #expect(rows.first?.terminalKey == "session-1")
    #expect(rows.first?.sessionId == "session-1")
    #expect(rows.first?.projectPath == "/tmp/project")
    #expect(rows.first?.expectedExecutable == "claude")
    #expect(rows.first?.registeredAt == registeredAt)
  }

  @Test("Register only persists owned process groups")
  func registerOnlyPersistsOwnedProcessGroups() async throws {
    let store = MockManagedProcessStore()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        123: identity(pid: 123, groupId: 999, startTime: 1_000)
      ]),
      processTerminator: MockProcessTerminator()
    )

    await registry.register(pid: 123)

    let rows = try await store.getManagedProcesses()
    #expect(rows.count == 1)
    #expect(rows.first?.processGroupId == nil)
  }

  @Test("Unregister removes persisted row")
  func unregisterRemovesPersistedRow() async throws {
    let store = MockManagedProcessStore()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        123: identity(pid: 123, groupId: 123, startTime: 1_000)
      ]),
      processTerminator: MockProcessTerminator()
    )

    await registry.register(pid: 123)
    #expect(try await store.getManagedProcesses().count == 1)

    await registry.unregister(pid: 123)
    #expect(try await store.getManagedProcesses().isEmpty)
  }

  @Test("Alive registered PIDs excludes dev servers and prunes stale terminal rows")
  func aliveRegisteredPIDsExcludeDevServersAndPruneStaleRows() async throws {
    let store = MockManagedProcessStore(records: [
      processRow(pid: 111, kind: .agentTerminal, startTime: 10),
      processRow(pid: 222, kind: .auxiliaryShell, startTime: 20),
      processRow(pid: 333, kind: .devServer, startTime: 30),
      processRow(pid: 444, kind: .agentTerminal, startTime: 40)
    ])
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        111: identity(pid: 111, groupId: 111, startTime: 10),
        222: identity(pid: 222, groupId: 222, startTime: 20),
        333: identity(pid: 333, groupId: 333, startTime: 30)
      ]),
      processTerminator: MockProcessTerminator()
    )

    let alive = await registry.getAliveRegisteredPIDs()

    #expect(alive == Set<Int32>([111, 222]))
    let remainingPIDs = try await store.getManagedProcesses().map(\.pid).sorted()
    #expect(remainingPIDs == [111, 222, 333])
  }

  @Test("Cleanup terminates matching identities and removes rows")
  func cleanupTerminatesMatchingIdentitiesAndRemovesRows() async throws {
    let store = MockManagedProcessStore(records: [
      processRow(pid: 111, kind: .agentTerminal, startTime: 10),
      processRow(pid: 222, kind: .devServer, startTime: 20)
    ])
    let terminator = MockProcessTerminator()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        111: identity(pid: 111, groupId: 111, startTime: 10),
        222: identity(pid: 222, groupId: 222, startTime: 20)
      ]),
      processTerminator: terminator
    )

    await registry.cleanupRegisteredProcesses()

    #expect(await terminator.terminatedPIDs().sorted() == [111, 222])
    #expect(try await store.getManagedProcesses().isEmpty)
  }

  @Test("Cleanup terminates inherited process group rows by PID only")
  func cleanupTerminatesInheritedProcessGroupRowsByPIDOnly() async throws {
    let store = MockManagedProcessStore(records: [
      processRow(pid: 111, kind: .agentTerminal, startTime: 10, processGroupId: 999)
    ])
    let terminator = MockProcessTerminator()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        111: identity(pid: 111, groupId: 999, startTime: 10)
      ]),
      processTerminator: terminator
    )

    await registry.cleanupRegisteredProcesses()

    #expect(await terminator.terminationRequests() == [
      TerminationRequest(pid: 111, processGroupId: nil)
    ])
    #expect(try await store.getManagedProcesses().isEmpty)
  }

  @Test("Orphan cleanup only terminates scoped inactive terminal rows")
  func orphanCleanupOnlyTerminatesScopedInactiveTerminalRows() async throws {
    let store = MockManagedProcessStore(records: [
      processRow(pid: 111, kind: .agentTerminal, startTime: 10, provider: .claude),
      processRow(pid: 222, kind: .auxiliaryShell, startTime: 20, provider: .claude),
      processRow(pid: 333, kind: .devServer, startTime: 30, provider: .claude),
      processRow(pid: 444, kind: .agentTerminal, startTime: 40, provider: .codex),
      processRow(pid: 555, kind: .agentTerminal, startTime: 50, provider: .claude)
    ])
    let terminator = MockProcessTerminator()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        111: identity(pid: 111, groupId: 111, startTime: 10),
        222: identity(pid: 222, groupId: 222, startTime: 20),
        333: identity(pid: 333, groupId: 333, startTime: 30),
        444: identity(pid: 444, groupId: 444, startTime: 40)
      ]),
      processTerminator: terminator
    )

    await registry.cleanupOrphanedTerminalProcesses(provider: .claude, activePIDs: [222])

    #expect(await terminator.terminatedPIDs() == [111])
    #expect(try await store.getManagedProcesses().map(\.pid).sorted() == [222, 333, 444])
  }

  @Test("Cleanup prunes PID reuse without terminating")
  func cleanupPrunesPIDReuseWithoutTerminating() async throws {
    let store = MockManagedProcessStore(records: [
      processRow(pid: 111, kind: .agentTerminal, startTime: 10)
    ])
    let terminator = MockProcessTerminator()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        111: identity(pid: 111, groupId: 111, startTime: 99)
      ]),
      processTerminator: terminator
    )

    await registry.cleanupRegisteredProcesses()

    #expect(await terminator.terminatedPIDs().isEmpty)
    #expect(try await store.getManagedProcesses().isEmpty)
  }

  @Test("Cleanup prunes dead processes without terminating")
  func cleanupPrunesDeadProcessesWithoutTerminating() async throws {
    let store = MockManagedProcessStore(records: [
      processRow(pid: 111, kind: .agentTerminal, startTime: 10)
    ])
    let terminator = MockProcessTerminator()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [:]),
      processTerminator: terminator
    )

    await registry.cleanupRegisteredProcesses()

    #expect(await terminator.terminatedPIDs().isEmpty)
    #expect(try await store.getManagedProcesses().isEmpty)
  }

  @Test("Late register request is ignored after unregister")
  func lateRegisterRequestIsIgnoredAfterUnregister() async throws {
    let store = MockManagedProcessStore()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        111: identity(pid: 111, groupId: 111, startTime: 10)
      ]),
      processTerminator: MockProcessTerminator()
    )

    await registry.unregister(pid: 111, requestedAt: Date(timeIntervalSince1970: 20))
    await registry.register(pid: 111, requestedAt: Date(timeIntervalSince1970: 10))

    #expect(try await store.getManagedProcesses().isEmpty)
  }

  @Test("Legacy UserDefaults registry data is ignored")
  func legacyUserDefaultsRegistryDataIsIgnored() async throws {
    let legacyKey = "AgentHub.TerminalProcessRegistry"
    UserDefaults.standard.set(["111": 1_700_000_000.0], forKey: legacyKey)
    defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

    let store = MockManagedProcessStore()
    let registry = TerminalProcessRegistry(
      store: store,
      processInspector: MockProcessInspector(identities: [
        111: identity(pid: 111, groupId: 111, startTime: 10)
      ]),
      processTerminator: MockProcessTerminator()
    )

    #expect(await registry.getAliveRegisteredPIDs().isEmpty)
    #expect(try await store.getManagedProcesses().isEmpty)
  }
}

private actor MockManagedProcessStore: ManagedProcessStoreProtocol {
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

private actor MockProcessInspector: ProcessInspecting {
  private var identities: [pid_t: ManagedProcessIdentity]

  init(identities: [pid_t: ManagedProcessIdentity]) {
    self.identities = identities
  }

  func identity(for pid: pid_t) async -> ManagedProcessIdentity? {
    identities[pid]
  }
}

private struct TerminationRequest: Equatable, Sendable {
  let pid: pid_t
  let processGroupId: pid_t?
}

private actor MockProcessTerminator: ProcessTerminating {
  private var requests: [TerminationRequest] = []

  func terminate(pid: pid_t, processGroupId: pid_t?) async {
    requests.append(TerminationRequest(pid: pid, processGroupId: processGroupId))
  }

  func terminatedPIDs() -> [pid_t] {
    requests.map(\.pid)
  }

  func terminationRequests() -> [TerminationRequest] {
    requests
  }
}

private func identity(pid: pid_t, groupId: pid_t, startTime: Int64) -> ManagedProcessIdentity {
  ManagedProcessIdentity(
    pid: pid,
    processGroupId: groupId,
    startTimeSeconds: startTime,
    commandLine: nil
  )
}

private func processRow(
  pid: Int32,
  kind: ManagedProcessKind,
  startTime: Int64,
  provider: SessionProviderKind? = nil
) -> ManagedProcessRecord {
  processRow(
    pid: pid,
    kind: kind,
    startTime: startTime,
    processGroupId: pid,
    provider: provider
  )
}

private func processRow(
  pid: Int32,
  kind: ManagedProcessKind,
  startTime: Int64,
  processGroupId: Int32,
  provider: SessionProviderKind? = nil
) -> ManagedProcessRecord {
  ManagedProcessRecord(
    pid: pid,
    processGroupId: processGroupId,
    processStartTimeSeconds: startTime,
    kind: kind,
    provider: provider?.rawValue,
    terminalKey: nil,
    sessionId: nil,
    projectPath: nil,
    expectedExecutable: nil,
    registeredAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2)
  )
}
