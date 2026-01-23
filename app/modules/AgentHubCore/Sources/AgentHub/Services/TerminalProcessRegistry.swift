//
//  TerminalProcessRegistry.swift
//  AgentHub
//
//  Tracks embedded-terminal PIDs so only app-spawned sessions are terminated.
//

import Darwin
import Foundation

final class TerminalProcessRegistry {
  static let shared = TerminalProcessRegistry()

  private let lock = NSLock()
  private let storageKey = "AgentHub.TerminalProcessRegistry"
  private var entries: [Int32: TimeInterval] = [:]

  private init() {
    load()
  }

  func register(pid: pid_t) {
    guard pid > 0 else { return }
    lock.lock()
    entries[pid] = Date().timeIntervalSince1970
    pruneTerminatedLocked()
    persistLocked()
    lock.unlock()
  }

  func unregister(pid: pid_t) {
    guard pid > 0 else { return }
    lock.lock()
    entries.removeValue(forKey: pid)
    persistLocked()
    lock.unlock()
  }

  /// Kills only processes previously spawned by the app.
  func cleanupRegisteredProcesses() {
    let snapshot = snapshotEntries()
    guard !snapshot.isEmpty else { return }

    for (pid, _) in snapshot {
      guard pid > 0 else {
        unregister(pid: pid)
        continue
      }

      guard isProcessAlive(pid) else {
        unregister(pid: pid)
        continue
      }

      if let command = processCommandLine(pid),
         !command.localizedCaseInsensitiveContains("claude") {
        // PID reused or not a Claude process; avoid killing.
        unregister(pid: pid)
        continue
      }

      terminateProcessGroup(pid)

      if !isProcessAlive(pid) {
        unregister(pid: pid)
      } else {
        AppLogger.session.warning("Failed to terminate registered Claude process PID=\(pid)")
      }
    }
  }

  // MARK: - Private

  private func snapshotEntries() -> [Int32: TimeInterval] {
    lock.lock()
    let copy = entries
    lock.unlock()
    return copy
  }

  private func load() {
    guard let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] else {
      return
    }

    for (key, value) in dict {
      if let pid = Int32(key) {
        entries[pid] = value
      }
    }
  }

  private func persistLocked() {
    var dict: [String: Double] = [:]
    for (pid, value) in entries {
      dict[String(pid)] = value
    }
    UserDefaults.standard.set(dict, forKey: storageKey)
  }

  private func pruneTerminatedLocked() {
    for pid in Array(entries.keys) {
      if !isProcessAlive(pid) {
        entries.removeValue(forKey: pid)
      }
    }
  }

  private func isProcessAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
  }

  private func processCommandLine(_ pid: pid_t) -> String? {
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
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }

  private func terminateProcessGroup(_ pid: pid_t) {
    if killpg(pid, SIGTERM) != 0 {
      _ = kill(pid, SIGTERM)
    }
    usleep(150_000) // 150ms
    if isProcessAlive(pid) {
      _ = killpg(pid, SIGKILL)
    }
  }
}
