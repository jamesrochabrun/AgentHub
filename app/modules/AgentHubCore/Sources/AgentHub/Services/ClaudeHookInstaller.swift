import Foundation
import os

// MARK: - ClaudeHookInstallerProtocol

public protocol ClaudeHookInstallerProtocol: AnyObject, Sendable {
  func isEnabled() async -> Bool
  func setEnabled(_ enabled: Bool) async
  /// Declares the complete set of project/worktree paths that should have the
  /// hook registered. The installer:
  /// - installs into paths in `paths` that aren't already installed,
  /// - uninstalls from every previously-installed path not in `paths`,
  /// - is idempotent when the state already matches.
  /// This is the only install API callers should use — per-session
  /// `ensureInstalled`/`releaseInstalled` was removed because Claude Code
  /// loads `settings.local.json` once at session start and wouldn't pick up a
  /// mid-session install.
  func syncInstalledPaths(_ paths: Set<String>) async
  /// Remove every installed entry. Called on Settings toggle off / app quit.
  func flushAll() async
  /// Launch-time housekeeping: uninstall previously-installed paths that
  /// aren't in `expectedPaths`. Provides a best-effort starting set before
  /// `syncInstalledPaths` takes over.
  func reconcileOnLaunch(expectedPaths: [String]) async
}

public protocol ClaudeHookInstallStateStoreProtocol: Sendable {
  func loadClaudeHookInstalledPaths() async throws -> Set<String>
  func replaceClaudeHookInstalledPaths(_ paths: Set<String>) async throws
}

// MARK: - ClaudeHookInstaller

/// Registers the AgentHub approval hook in each monitored project's
/// `.claude/settings.local.json`. The hook script itself lives in
/// `~/Library/Application Support/AgentHub/hooks/agenthub-approval.sh` (one
/// copy for the whole app) — we never place a script inside the project's
/// `.claude/` directory, so there is no chance of it being accidentally
/// committed to git.
public actor ClaudeHookInstaller: ClaudeHookInstallerProtocol {

  // MARK: - Constants

  /// UserDefaults key for the master toggle. Default on.
  public static let enabledKey = "com.agenthub.claudeHook.enabled"

  // MARK: - Properties

  private let fileManager: FileManager
  private let defaults: UserDefaults
  private let stateStore: any ClaudeHookInstallStateStoreProtocol
  private let bundledScriptURL: URL?
  private let sharedScriptURL: URL

  // MARK: - Initialization

  public init(
    stateStore: any ClaudeHookInstallStateStoreProtocol,
    fileManager: FileManager = .default,
    defaults: UserDefaults = .standard,
    bundledScriptURL: URL? = ClaudeHookPaths.bundledScriptURL(),
    sharedScriptURL: URL = ClaudeHookPaths.sharedScriptURL
  ) {
    self.fileManager = fileManager
    self.defaults = defaults
    self.stateStore = stateStore
    self.bundledScriptURL = bundledScriptURL
    self.sharedScriptURL = sharedScriptURL
  }

  // MARK: - Toggle

  public func isEnabled() async -> Bool {
    if defaults.object(forKey: Self.enabledKey) == nil { return true }
    return defaults.bool(forKey: Self.enabledKey)
  }

  public func setEnabled(_ enabled: Bool) async {
    defaults.set(enabled, forKey: Self.enabledKey)
    if !enabled {
      await sweepAllInstalledPaths()
    }
    // Re-enable is intentionally a no-op here; the next `syncInstalledPaths`
    // call from the repositories subscription will re-install wherever needed.
  }

  // MARK: - Install / sync

  public func syncInstalledPaths(_ paths: Set<String>) async {
    guard await isEnabled() else {
      // Feature disabled: make sure nothing is installed anywhere.
      await sweepAllInstalledPaths()
      return
    }

    guard var trackedPaths = await loadInstalledPaths() else { return }

    let toInstall = paths.subtracting(trackedPaths)
    let toUninstall = trackedPaths.subtracting(paths)
    let toRepair = paths
      .intersection(trackedPaths)
      .filter { installNeedsRepair(atProjectPath: $0) }

    if toInstall.isEmpty && toUninstall.isEmpty && toRepair.isEmpty {
      return
    }

    if !toInstall.isEmpty {
      let expandedPaths = trackedPaths.union(toInstall)
      guard await replaceInstalledPaths(expandedPaths) else { return }
      trackedPaths = expandedPaths
    }

    let persistedPaths = trackedPaths

    if !toInstall.isEmpty || !toRepair.isEmpty {
      ensureSharedScript()
    }

    for path in toUninstall {
      if uninstall(atProjectPath: path) {
        trackedPaths.remove(path)
      }
    }
    for path in toInstall {
      _ = install(atProjectPath: path)
    }
    for path in toRepair {
      _ = install(atProjectPath: path)
    }

    if trackedPaths != persistedPaths {
      _ = await replaceInstalledPaths(trackedPaths)
    }
  }

  public func flushAll() async {
    await sweepAllInstalledPaths()
  }

  public func reconcileOnLaunch(expectedPaths: [String]) async {
    let expected = Set(expectedPaths)
    guard let previouslyInstalled = await loadInstalledPaths() else { return }
    let stale = previouslyInstalled.subtracting(expected)
    var finalInstalled = previouslyInstalled
    for path in stale {
      if uninstall(atProjectPath: path) {
        finalInstalled.remove(path)
      }
    }
    if finalInstalled != previouslyInstalled {
      _ = await replaceInstalledPaths(finalInstalled)
    }
  }

  // MARK: - Install / uninstall mechanics

  @discardableResult
  private func install(atProjectPath path: String) -> Bool {
    let settingsURL = ClaudeHookPaths.settingsLocalURL(inProjectAt: path)
    do {
      removeLegacyPerProjectScriptIfPresent(atProjectPath: path)
      try mergeSettingsLocal(
        at: settingsURL,
        scriptPath: sharedScriptURL.path,
        legacyScriptPath: legacyPerProjectScriptURL(atProjectPath: path).path
      )
      return true
    } catch {
      AppLogger.watcher.error("[ClaudeHookInstaller] install failed for \(path): \(error.localizedDescription)")
      return false
    }
  }

  @discardableResult
  private func uninstall(atProjectPath path: String) -> Bool {
    let settingsURL = ClaudeHookPaths.settingsLocalURL(inProjectAt: path)
    do {
      removeLegacyPerProjectScriptIfPresent(atProjectPath: path)
      if fileManager.fileExists(atPath: settingsURL.path) {
        try unmergeSettingsLocal(
          at: settingsURL,
          scriptPaths: [
            sharedScriptURL.path,
            legacyPerProjectScriptURL(atProjectPath: path).path,
          ]
        )
      }
      return true
    } catch {
      AppLogger.watcher.error("[ClaudeHookInstaller] uninstall failed for \(path): \(error.localizedDescription)")
      return false
    }
  }

  /// One-time migration for users upgrading from the earlier design that
  /// placed `agenthub-approval.sh` inside each project's `.claude/hooks/`
  /// directory. Removes the legacy script and any `settings.local.json` entry
  /// that still references it. Safe to run on every install/uninstall call
  /// because it only acts on our uniquely-named script.
  private func legacyPerProjectScriptURL(atProjectPath path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("hooks", isDirectory: true)
      .appendingPathComponent("agenthub-approval.sh", isDirectory: false)
  }

  private func removeLegacyPerProjectScriptIfPresent(atProjectPath path: String) {
    let legacyScript = legacyPerProjectScriptURL(atProjectPath: path)
    if fileManager.fileExists(atPath: legacyScript.path) {
      try? fileManager.removeItem(at: legacyScript)
    }
  }

  private func sweepAllInstalledPaths() async {
    guard let previouslyInstalled = await loadInstalledPaths() else { return }
    var finalInstalled = previouslyInstalled
    for path in previouslyInstalled {
      if uninstall(atProjectPath: path) {
        finalInstalled.remove(path)
      }
    }
    if finalInstalled != previouslyInstalled {
      _ = await replaceInstalledPaths(finalInstalled)
    }
  }

  // MARK: - Shared script management

  private func ensureSharedScript() {
    guard let bundledScriptURL else {
      AppLogger.watcher.error("[ClaudeHookInstaller] Bundled script missing; can't install shared script")
      return
    }
    do {
      try fileManager.createDirectory(
        at: sharedScriptURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if !fileManager.fileExists(atPath: sharedScriptURL.path) || !scriptContentMatches(sharedScriptURL) {
        if fileManager.fileExists(atPath: sharedScriptURL.path) {
          try fileManager.removeItem(at: sharedScriptURL)
        }
        try fileManager.copyItem(at: bundledScriptURL, to: sharedScriptURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedScriptURL.path)
      }
    } catch {
      AppLogger.watcher.error("[ClaudeHookInstaller] ensureSharedScript failed: \(error.localizedDescription)")
    }
  }

  private func scriptContentMatches(_ installedURL: URL) -> Bool {
    guard let bundledScriptURL,
          let a = try? Data(contentsOf: bundledScriptURL),
          let b = try? Data(contentsOf: installedURL) else { return false }
    return a == b
  }

  // MARK: - settings.local.json merge

  private func installNeedsRepair(atProjectPath path: String) -> Bool {
    let settingsURL = ClaudeHookPaths.settingsLocalURL(inProjectAt: path)
    guard fileManager.fileExists(atPath: settingsURL.path),
          let data = try? Data(contentsOf: settingsURL),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hooks = root["hooks"] as? [String: Any] else {
      return true
    }

    let legacyScriptPath = legacyPerProjectScriptURL(atProjectPath: path).path
    let pre = inspectEventEntry(
      hooks["PreToolUse"],
      scriptPath: sharedScriptURL.path,
      legacyScriptPath: legacyScriptPath
    )
    let post = inspectEventEntry(
      hooks["PostToolUse"],
      scriptPath: sharedScriptURL.path,
      legacyScriptPath: legacyScriptPath
    )

    return !pre.hasCurrentEntry
      || !post.hasCurrentEntry
      || pre.hasDuplicateAgentHubEntries
      || post.hasDuplicateAgentHubEntries
      || pre.hasLegacyPerProjectReference
      || post.hasLegacyPerProjectReference
  }

  private func mergeSettingsLocal(at url: URL, scriptPath: String, legacyScriptPath: String) throws {
    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      root = parsed
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var didChange = false
    let pre = upsertEventEntry(
      in: hooks,
      event: "PreToolUse",
      scriptPath: scriptPath,
      legacyScriptPath: legacyScriptPath
    )
    hooks = pre.hooks
    didChange = didChange || pre.didChange

    let post = upsertEventEntry(
      in: hooks,
      event: "PostToolUse",
      scriptPath: scriptPath,
      legacyScriptPath: legacyScriptPath
    )
    hooks = post.hooks
    didChange = didChange || post.didChange

    guard didChange else { return }
    root["hooks"] = hooks
    try writeJSON(root, to: url)
  }

  private func unmergeSettingsLocal(at url: URL, scriptPaths: [String]) throws {
    guard let data = try? Data(contentsOf: url),
          var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }
    guard var hooks = root["hooks"] as? [String: Any] else { return }
    var didChange = false
    let pre = removeEventEntry(in: hooks, event: "PreToolUse", scriptPaths: scriptPaths)
    hooks = pre.hooks
    didChange = didChange || pre.didChange

    let post = removeEventEntry(in: hooks, event: "PostToolUse", scriptPaths: scriptPaths)
    hooks = post.hooks
    didChange = didChange || post.didChange

    guard didChange else { return }
    if hooks.isEmpty {
      root.removeValue(forKey: "hooks")
    } else {
      root["hooks"] = hooks
    }
    if root.isEmpty {
      try fileManager.removeItem(at: url)
      return
    }
    try writeJSON(root, to: url)
  }

  private func upsertEventEntry(
    in hooks: [String: Any],
    event: String,
    scriptPath: String,
    legacyScriptPath: String
  ) -> (hooks: [String: Any], didChange: Bool) {
    var result = hooks
    let eventValue = result[event]
    let inspection = inspectEventEntry(
      eventValue,
      scriptPath: scriptPath,
      legacyScriptPath: legacyScriptPath
    )

    if inspection.hasCurrentEntry,
       !inspection.hasDuplicateAgentHubEntries,
       !inspection.hasLegacyPerProjectReference {
      return (result, false)
    }

    var entries = (eventValue as? [[String: Any]]) ?? []
    entries = removeAgentHubCommands(
      from: entries,
      scriptPaths: [scriptPath, legacyScriptPath]
    )
    entries.append([
      "matcher": "*",
      "hooks": [
        [
          "type": "command",
          "command": Self.shellQuoted(scriptPath),
        ] as [String: Any],
      ],
    ])
    result[event] = entries
    return (result, true)
  }

  private func removeEventEntry(
    in hooks: [String: Any],
    event: String,
    scriptPaths: [String]
  ) -> (hooks: [String: Any], didChange: Bool) {
    var result = hooks
    guard let originalEntries = result[event] as? [[String: Any]] else {
      return (result, false)
    }
    let entries = removeAgentHubCommands(from: originalEntries, scriptPaths: scriptPaths)
    let didChange = agentHubCommandCount(in: originalEntries, scriptPaths: scriptPaths) > 0
    guard didChange else { return (result, false) }
    if entries.isEmpty {
      result.removeValue(forKey: event)
    } else {
      result[event] = entries
    }
    return (result, true)
  }

  private struct EventEntryInspection {
    let hasCurrentEntry: Bool
    let hasDuplicateAgentHubEntries: Bool
    let hasLegacyPerProjectReference: Bool
  }

  private func inspectEventEntry(
    _ eventValue: Any?,
    scriptPath: String,
    legacyScriptPath: String
  ) -> EventEntryInspection {
    guard let entries = eventValue as? [[String: Any]] else {
      return EventEntryInspection(
        hasCurrentEntry: false,
        hasDuplicateAgentHubEntries: false,
        hasLegacyPerProjectReference: false
      )
    }

    var currentCount = 0
    var agentHubCount = 0
    var hasLegacy = false
    let currentCommand = Self.shellQuoted(scriptPath)
    let legacyCommands = Set([legacyScriptPath, Self.shellQuoted(legacyScriptPath)])

    for entry in entries {
      let inner = entry["hooks"] as? [[String: Any]] ?? []
      for hook in inner {
        guard let command = hook["command"] as? String else { continue }
        if command == currentCommand {
          currentCount += 1
          agentHubCount += 1
        } else if command == scriptPath || legacyCommands.contains(command) {
          agentHubCount += 1
          if legacyCommands.contains(command) {
            hasLegacy = true
          }
        }
      }
    }

    return EventEntryInspection(
      hasCurrentEntry: currentCount == 1,
      hasDuplicateAgentHubEntries: agentHubCount > 1,
      hasLegacyPerProjectReference: hasLegacy
    )
  }

  private func removeAgentHubCommands(
    from entries: [[String: Any]],
    scriptPaths: [String]
  ) -> [[String: Any]] {
    entries.compactMap { entry in
      guard let inner = entry["hooks"] as? [[String: Any]] else { return entry }
      var cleaned = entry
      let filtered = inner.filter {
        !isOurCommand($0["command"] as? String, scriptPaths: scriptPaths)
      }
      guard filtered.count != inner.count else { return entry }
      guard !filtered.isEmpty else { return nil }
      cleaned["hooks"] = filtered
      return cleaned
    }
  }

  private func agentHubCommandCount(in entries: [[String: Any]], scriptPaths: [String]) -> Int {
    entries.reduce(0) { count, entry in
      let inner = entry["hooks"] as? [[String: Any]] ?? []
      return count + inner.filter {
        isOurCommand($0["command"] as? String, scriptPaths: scriptPaths)
      }.count
    }
  }

  /// Matches both the current shell-quoted form and the legacy unquoted form
  /// so that older installations get cleanly upgraded on the next sync.
  private func isOurCommand(_ command: String?, scriptPaths: [String]) -> Bool {
    guard let command else { return false }
    return scriptPaths.contains { command == $0 || command == Self.shellQuoted($0) }
  }

  /// Wraps a path in single quotes so `/bin/sh -c` doesn't word-split on
  /// embedded spaces (e.g. `~/Library/Application Support/...`). Embedded
  /// single quotes are escaped as `'\''`.
  static func shellQuoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func writeJSON(_ object: [String: Any], to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url, options: .atomic)
  }

  // MARK: - Persistence of installed paths

  private func loadInstalledPaths() async -> Set<String>? {
    do {
      return try await stateStore.loadClaudeHookInstalledPaths()
    } catch {
      AppLogger.watcher.error("[ClaudeHookInstaller] failed to load installed paths; skipping hook changes: \(error.localizedDescription)")
      return nil
    }
  }

  private func replaceInstalledPaths(_ paths: Set<String>) async -> Bool {
    do {
      try await stateStore.replaceClaudeHookInstalledPaths(paths)
      return true
    } catch {
      AppLogger.watcher.error("[ClaudeHookInstaller] failed to save installed paths; skipping hook changes: \(error.localizedDescription)")
      return false
    }
  }
}

actor NoOpClaudeHookInstaller: ClaudeHookInstallerProtocol {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func isEnabled() async -> Bool {
    if defaults.object(forKey: ClaudeHookInstaller.enabledKey) == nil { return true }
    return defaults.bool(forKey: ClaudeHookInstaller.enabledKey)
  }

  func setEnabled(_ enabled: Bool) async {
    defaults.set(enabled, forKey: ClaudeHookInstaller.enabledKey)
  }

  func syncInstalledPaths(_ paths: Set<String>) async {}
  func flushAll() async {}
  func reconcileOnLaunch(expectedPaths: [String]) async {}
}
