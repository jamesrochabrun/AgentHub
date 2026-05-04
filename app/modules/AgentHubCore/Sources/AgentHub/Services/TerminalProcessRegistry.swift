//
//  TerminalProcessRegistry.swift
//  AgentHub
//
//  Tracks app-spawned process identities so crash recovery can clean them up
//  without relying on UserDefaults or killing unrelated PID-reused processes.
//

import Darwin
import Foundation

struct ManagedProcessIdentity: Equatable, Sendable {
  let pid: pid_t
  let processGroupId: pid_t
  let startTimeSeconds: Int64
  let commandLine: String?
}

protocol ProcessInspecting: Sendable {
  func identity(for pid: pid_t) async -> ManagedProcessIdentity?
}

protocol ProcessTerminating: Sendable {
  func terminate(pid: pid_t, processGroupId: pid_t?) async
}

struct DarwinProcessInspector: ProcessInspecting {
  func identity(for pid: pid_t) async -> ManagedProcessIdentity? {
    guard pid > 0, kill(pid, 0) == 0 else { return nil }
    guard let bsdInfo = bsdInfo(for: pid) else { return nil }

    return ManagedProcessIdentity(
      pid: pid,
      processGroupId: pid_t(bsdInfo.pbi_pgid),
      startTimeSeconds: Int64(bsdInfo.pbi_start_tvsec),
      commandLine: commandLine(for: pid)
    )
  }

  private func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let result = withUnsafeMutableBytes(of: &info) { buffer in
      proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        buffer.baseAddress,
        Int32(buffer.count)
      )
    }

    guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else {
      return nil
    }
    return info
  }

  private func commandLine(for pid: pid_t) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", "\(pid)", "-o", "command="]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()

    do {
      try task.run()
      task.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let command = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return command?.isEmpty == false ? command : nil
    } catch {
      return nil
    }
  }
}

struct DarwinProcessTerminator: ProcessTerminating {
  func terminate(pid: pid_t, processGroupId: pid_t?) async {
    guard pid > 0 else { return }

    if let groupId = ownedProcessGroupId(pid: pid, processGroupId: processGroupId) {
      if killpg(groupId, SIGTERM) != 0 {
        _ = kill(pid, SIGTERM)
      }
    } else {
      _ = kill(pid, SIGTERM)
    }

    try? await Task.sleep(for: .milliseconds(300))

    guard kill(pid, 0) == 0 else { return }
    if let groupId = ownedProcessGroupId(pid: pid, processGroupId: processGroupId) {
      if killpg(groupId, SIGKILL) != 0 {
        _ = kill(pid, SIGKILL)
      }
    } else {
      _ = kill(pid, SIGKILL)
    }

    try? await Task.sleep(for: .milliseconds(100))
  }

  private func ownedProcessGroupId(pid: pid_t, processGroupId: pid_t?) -> pid_t? {
    guard let processGroupId, processGroupId > 0, processGroupId == pid else {
      return nil
    }
    return processGroupId
  }
}

public actor TerminalProcessRegistry {
  public static let shared = TerminalProcessRegistry()

  private enum CleanupScope {
    case allRegistered
    case orphanedTerminals(provider: SessionProviderKind?, activePIDs: Set<Int32>)
  }

  private let processInspector: any ProcessInspecting
  private let processTerminator: any ProcessTerminating
  private var processStore: (any ManagedProcessStoreProtocol)?
  private var didAttemptDefaultStore = false
  private var unregisterRequests: [pid_t: Date] = [:]

  init(
    store: (any ManagedProcessStoreProtocol)? = nil,
    processInspector: any ProcessInspecting = DarwinProcessInspector(),
    processTerminator: any ProcessTerminating = DarwinProcessTerminator()
  ) {
    self.processStore = store
    self.processInspector = processInspector
    self.processTerminator = processTerminator
    self.didAttemptDefaultStore = store != nil
  }

  public func configure(store: (any ManagedProcessStoreProtocol)?) {
    processStore = store
    didAttemptDefaultStore = store != nil
  }

  public func register(
    pid: pid_t,
    kind: ManagedProcessKind = .agentTerminal,
    provider: SessionProviderKind? = nil,
    terminalKey: String? = nil,
    sessionId: String? = nil,
    projectPath: String? = nil,
    expectedExecutable: String? = nil,
    requestedAt: Date = Date.now
  ) async {
    guard pid > 0 else { return }
    guard !shouldIgnoreRegistration(pid: pid, requestedAt: requestedAt) else { return }
    guard let identity = await processInspector.identity(for: pid) else {
      await deleteManagedProcess(pid: pid)
      return
    }
    guard !shouldIgnoreRegistration(pid: pid, requestedAt: requestedAt) else { return }
    guard let store = await resolvedProcessStore() else { return }

    let record = ManagedProcessRecord(
      pid: pid,
      processGroupId: ownedProcessGroupId(for: identity),
      processStartTimeSeconds: identity.startTimeSeconds,
      kind: kind,
      provider: provider?.rawValue,
      terminalKey: normalized(terminalKey),
      sessionId: normalized(sessionId),
      projectPath: normalized(projectPath),
      expectedExecutable: normalized(expectedExecutable),
      registeredAt: requestedAt,
      updatedAt: Date.now
    )

    do {
      try await store.saveManagedProcess(record)
    } catch {
      AppLogger.session.error("Failed to persist managed process PID=\(pid): \(error.localizedDescription)")
    }
  }

  public func unregister(pid: pid_t, requestedAt: Date = Date.now) async {
    guard pid > 0 else { return }
    unregisterRequests[pid] = requestedAt
    pruneOldUnregisterRequests(relativeTo: requestedAt)
    await deleteManagedProcess(pid: pid)
  }

  /// Returns live terminal PIDs still owned by AgentHub. Dev-server rows are
  /// intentionally excluded because this count backs the terminal orphan UI.
  public func getAliveRegisteredPIDs(provider: SessionProviderKind? = nil) async -> Set<Int32> {
    guard let store = await resolvedProcessStore() else { return [] }

    do {
      let rows = try await store.getManagedProcesses()
      var stalePIDs: [Int32] = []
      var alivePIDs: Set<Int32> = []

      for row in rows where row.processKind?.isTerminalProcess == true
        && matchesProvider(row, provider: provider) {
        guard let identity = await processInspector.identity(for: row.pid) else {
          stalePIDs.append(row.pid)
          continue
        }
        guard matchesStoredIdentity(row, identity: identity) else {
          stalePIDs.append(row.pid)
          continue
        }
        alivePIDs.insert(row.pid)
      }

      try await store.deleteManagedProcesses(pids: stalePIDs)
      return alivePIDs
    } catch {
      AppLogger.session.error("Failed to load managed process rows: \(error.localizedDescription)")
      return []
    }
  }

  /// Terminates every live process still matching its persisted app-spawned
  /// identity, and prunes stale rows without killing PID-reused processes.
  public func cleanupRegisteredProcesses() async {
    await cleanupManagedProcesses(scope: .allRegistered)
  }

  /// Terminates terminal rows that are live, provider-scoped, and no longer
  /// attached to active UI terminals. Dev servers and active terminal rows are
  /// intentionally left alone because this backs the menu-bar orphan action.
  public func cleanupOrphanedTerminalProcesses(
    provider: SessionProviderKind? = nil,
    activePIDs: Set<Int32>
  ) async {
    await cleanupManagedProcesses(
      scope: .orphanedTerminals(provider: provider, activePIDs: activePIDs)
    )
  }

  private func cleanupManagedProcesses(scope: CleanupScope) async {
    guard let store = await resolvedProcessStore() else { return }

    do {
      let rows = try await store.getManagedProcesses()
      guard !rows.isEmpty else { return }

      var completedPIDs: [Int32] = []
      for row in rows where shouldCleanup(row, scope: scope) {
        guard row.processKind != nil else {
          completedPIDs.append(row.pid)
          continue
        }

        guard let identity = await processInspector.identity(for: row.pid) else {
          completedPIDs.append(row.pid)
          continue
        }

        guard matchesStoredIdentity(row, identity: identity) else {
          completedPIDs.append(row.pid)
          continue
        }

        await processTerminator.terminate(
          pid: row.pid,
          processGroupId: ownedProcessGroupId(for: row, identity: identity)
        )
        completedPIDs.append(row.pid)
      }

      try await store.deleteManagedProcesses(pids: completedPIDs)
    } catch {
      AppLogger.session.error("Failed to clean up managed processes: \(error.localizedDescription)")
    }
  }

  private func shouldCleanup(_ row: ManagedProcessRecord, scope: CleanupScope) -> Bool {
    switch scope {
    case .allRegistered:
      return true
    case .orphanedTerminals(let provider, let activePIDs):
      guard row.processKind?.isTerminalProcess == true else { return false }
      guard matchesProvider(row, provider: provider) else { return false }
      return !activePIDs.contains(row.pid)
    }
  }

  private func resolvedProcessStore() async -> (any ManagedProcessStoreProtocol)? {
    if let processStore {
      return processStore
    }

    guard !didAttemptDefaultStore else { return nil }
    didAttemptDefaultStore = true

    do {
      let store = try SessionMetadataStore()
      processStore = store
      return store
    } catch {
      AppLogger.session.error("Failed to create managed process store: \(error.localizedDescription)")
      return nil
    }
  }

  private func deleteManagedProcess(pid: pid_t) async {
    guard let store = await resolvedProcessStore() else { return }
    do {
      try await store.deleteManagedProcess(pid: pid)
    } catch {
      AppLogger.session.error("Failed to delete managed process PID=\(pid): \(error.localizedDescription)")
    }
  }

  private func matchesStoredIdentity(
    _ row: ManagedProcessRecord,
    identity: ManagedProcessIdentity
  ) -> Bool {
    guard let storedStartTime = row.processStartTimeSeconds else {
      return false
    }
    guard storedStartTime == identity.startTimeSeconds else {
      return false
    }

    if let storedGroupId = row.processGroupId, storedGroupId > 0 {
      return storedGroupId == identity.processGroupId
    }
    return true
  }

  private func shouldIgnoreRegistration(pid: pid_t, requestedAt: Date) -> Bool {
    guard let unregisterDate = unregisterRequests[pid] else { return false }
    return requestedAt <= unregisterDate
  }

  private func pruneOldUnregisterRequests(relativeTo now: Date) {
    guard unregisterRequests.count > 128 else { return }
    unregisterRequests = unregisterRequests.filter { _, date in
      now.timeIntervalSince(date) < 60
    }
  }

  private func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  private func matchesProvider(_ row: ManagedProcessRecord, provider: SessionProviderKind?) -> Bool {
    guard let provider else { return true }
    return row.provider == provider.rawValue
  }

  private func ownedProcessGroupId(for identity: ManagedProcessIdentity) -> pid_t? {
    guard identity.processGroupId > 0, identity.processGroupId == identity.pid else {
      return nil
    }
    return identity.processGroupId
  }

  private func ownedProcessGroupId(
    for row: ManagedProcessRecord,
    identity: ManagedProcessIdentity
  ) -> pid_t? {
    guard row.processGroupId == identity.processGroupId else {
      return nil
    }
    return ownedProcessGroupId(for: identity)
  }
}
