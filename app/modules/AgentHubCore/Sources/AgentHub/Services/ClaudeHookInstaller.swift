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

// MARK: - ClaudeHookInstaller

/// Registers the AgentHub approval hook in each monitored project's
/// `.claude/settings.local.json`. The hook script itself lives in
/// `~/Library/Application Support/AgentHub/hooks/agenthub-approval.sh` (one
/// copy for the whole app) — we never place a script inside the project's
/// `.claude/` directory, so there is no chance of it being accidentally
/// committed to git.
public actor ClaudeHookInstaller: ClaudeHookInstallerProtocol {

  // MARK: - Constants

  /// UserDefaults key storing the set of paths where the hook entry has been
  /// written, so `reconcileOnLaunch` and `flushAll` can sweep correctly.
  public static let installedPathsKey = "com.agenthub.claudeHook.installedPaths"

  /// UserDefaults key for the master toggle. Default on.
  public static let enabledKey = "com.agenthub.claudeHook.enabled"

  // MARK: - Properties

  private let fileManager: FileManager
  private let defaults: UserDefaults
  private let bundledScriptURL: URL?
  private let sharedScriptURL: URL

  // MARK: - Initialization

  public init(
    fileManager: FileManager = .default,
    defaults: UserDefaults = .standard,
    bundledScriptURL: URL? = ClaudeHookPaths.bundledScriptURL(),
    sharedScriptURL: URL = ClaudeHookPaths.sharedScriptURL
  ) {
    self.fileManager = fileManager
    self.defaults = defaults
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
      sweepAllInstalledPaths()
    }
    // Re-enable is intentionally a no-op here; the next `syncInstalledPaths`
    // call from the repositories subscription will re-install wherever needed.
  }

  // MARK: - Install / sync

  public func syncInstalledPaths(_ paths: Set<String>) async {
    guard await isEnabled() else {
      // Feature disabled: make sure nothing is installed anywhere.
      sweepAllInstalledPaths()
      return
    }
    ensureSharedScript()

    let previously = Set(loadInstalledPaths())
    let toInstall = paths.subtracting(previously)
    let toUninstall = previously.subtracting(paths)
    let toRepair = paths.intersection(previously) // ensure content is up to date

    for path in toUninstall {
      uninstall(atProjectPath: path)
    }
    for path in toInstall.union(toRepair) {
      install(atProjectPath: path)
    }
  }

  public func flushAll() async {
    sweepAllInstalledPaths()
  }

  public func reconcileOnLaunch(expectedPaths: [String]) async {
    let expected = Set(expectedPaths)
    let previouslyInstalled = Set(loadInstalledPaths())
    let stale = previouslyInstalled.subtracting(expected)
    for path in stale {
      uninstall(atProjectPath: path, updatesInstalledPaths: false)
    }
    saveInstalledPaths(Array(previouslyInstalled.subtracting(stale)))
  }

  // MARK: - Install / uninstall mechanics

  private func install(atProjectPath path: String) {
    let settingsURL = ClaudeHookPaths.settingsLocalURL(inProjectAt: path)
    do {
      migrateLegacyPerProjectScript(atProjectPath: path, settingsURL: settingsURL)
      try mergeSettingsLocal(at: settingsURL, scriptPath: sharedScriptURL.path)
      rememberInstalled(path: path)
    } catch {
      AppLogger.watcher.error("[ClaudeHookInstaller] install failed for \(path): \(error.localizedDescription)")
    }
  }

  private func uninstall(atProjectPath path: String, updatesInstalledPaths: Bool = true) {
    let settingsURL = ClaudeHookPaths.settingsLocalURL(inProjectAt: path)
    do {
      migrateLegacyPerProjectScript(atProjectPath: path, settingsURL: settingsURL)
      if fileManager.fileExists(atPath: settingsURL.path) {
        try unmergeSettingsLocal(at: settingsURL, scriptPath: sharedScriptURL.path)
      }
      if updatesInstalledPaths {
        forgetInstalled(path: path)
      }
    } catch {
      AppLogger.watcher.error("[ClaudeHookInstaller] uninstall failed for \(path): \(error.localizedDescription)")
    }
  }

  /// One-time migration for users upgrading from the earlier design that
  /// placed `agenthub-approval.sh` inside each project's `.claude/hooks/`
  /// directory. Removes the legacy script and any `settings.local.json` entry
  /// that still references it. Safe to run on every install/uninstall call
  /// because it only acts on our uniquely-named script.
  private func migrateLegacyPerProjectScript(atProjectPath path: String, settingsURL: URL) {
    let legacyScript = URL(fileURLWithPath: path, isDirectory: true)
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("hooks", isDirectory: true)
      .appendingPathComponent("agenthub-approval.sh", isDirectory: false)
    if fileManager.fileExists(atPath: legacyScript.path) {
      try? fileManager.removeItem(at: legacyScript)
    }
    // Also strip any `settings.local.json` entry that still points at the old
    // per-project path — we re-add ours pointing at the shared script next.
    if fileManager.fileExists(atPath: settingsURL.path) {
      try? unmergeSettingsLocal(at: settingsURL, scriptPath: legacyScript.path)
    }
  }

  private func sweepAllInstalledPaths() {
    for path in loadInstalledPaths() {
      uninstall(atProjectPath: path)
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

  private func mergeSettingsLocal(at url: URL, scriptPath: String) throws {
    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      root = parsed
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    hooks = upsertEventEntry(in: hooks, event: "PreToolUse", scriptPath: scriptPath)
    hooks = upsertEventEntry(in: hooks, event: "PostToolUse", scriptPath: scriptPath)
    root["hooks"] = hooks
    try writeJSON(root, to: url)
  }

  private func unmergeSettingsLocal(at url: URL, scriptPath: String) throws {
    guard let data = try? Data(contentsOf: url),
          var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }
    guard var hooks = root["hooks"] as? [String: Any] else { return }
    hooks = removeEventEntry(in: hooks, event: "PreToolUse", scriptPath: scriptPath)
    hooks = removeEventEntry(in: hooks, event: "PostToolUse", scriptPath: scriptPath)
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
    scriptPath: String
  ) -> [String: Any] {
    var result = hooks
    var entries = result[event] as? [[String: Any]] ?? []
    entries.removeAll { entry in
      guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
      return inner.contains { isOurCommand($0["command"] as? String, scriptPath: scriptPath) }
    }
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
    return result
  }

  private func removeEventEntry(
    in hooks: [String: Any],
    event: String,
    scriptPath: String
  ) -> [String: Any] {
    var result = hooks
    guard var entries = result[event] as? [[String: Any]] else { return result }
    entries.removeAll { entry in
      guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
      return inner.contains { isOurCommand($0["command"] as? String, scriptPath: scriptPath) }
    }
    if entries.isEmpty {
      result.removeValue(forKey: event)
    } else {
      result[event] = entries
    }
    return result
  }

  /// Matches both the current shell-quoted form and the legacy unquoted form
  /// so that older installations get cleanly upgraded on the next sync.
  private func isOurCommand(_ command: String?, scriptPath: String) -> Bool {
    guard let command else { return false }
    return command == scriptPath || command == Self.shellQuoted(scriptPath)
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

  private func loadInstalledPaths() -> [String] {
    (defaults.array(forKey: Self.installedPathsKey) as? [String]) ?? []
  }

  private func saveInstalledPaths(_ paths: [String]) {
    defaults.set(paths.sorted(), forKey: Self.installedPathsKey)
  }

  private func rememberInstalled(path: String) {
    var set = Set(loadInstalledPaths())
    set.insert(path)
    saveInstalledPaths(Array(set))
  }

  private func forgetInstalled(path: String) {
    var set = Set(loadInstalledPaths())
    set.remove(path)
    saveInstalledPaths(Array(set))
  }
}
