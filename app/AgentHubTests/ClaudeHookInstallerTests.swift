import Foundation
import Testing
@testable import AgentHubCore

@Suite("ClaudeHookInstaller")
struct ClaudeHookInstallerTests {

  // MARK: - Fixture

  private final class Fixture {
    let base: URL
    let projectA: URL
    let projectB: URL
    let bundledScriptURL: URL
    let sharedScriptURL: URL
    let defaults: UserDefaults
    let installer: ClaudeHookInstaller
    let suiteName: String

    init(name: String) throws {
      self.base = FileManager.default.temporaryDirectory
        .appendingPathComponent("agenthub-installer-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

      self.projectA = base.appendingPathComponent("projA", isDirectory: true)
      self.projectB = base.appendingPathComponent("projB", isDirectory: true)
      try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

      self.bundledScriptURL = base.appendingPathComponent("bundled-agenthub-approval.sh")
      try "#!/bin/bash\nexit 0\n".write(to: bundledScriptURL, atomically: true, encoding: .utf8)

      self.sharedScriptURL = base.appendingPathComponent("shared/hooks/agenthub-approval.sh")

      self.suiteName = "ClaudeHookInstallerTests.\(name).\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw NSError(domain: "fixture", code: 1)
      }
      self.defaults = defaults

      self.installer = ClaudeHookInstaller(
        fileManager: .default,
        defaults: defaults,
        bundledScriptURL: bundledScriptURL,
        sharedScriptURL: sharedScriptURL
      )
    }

    func teardown() {
      try? FileManager.default.removeItem(at: base)
      defaults.removePersistentDomain(forName: suiteName)
    }

    func settingsLocal(for project: URL) -> URL {
      ClaudeHookPaths.settingsLocalURL(inProjectAt: project.path)
    }

    func projectHooksDir(for project: URL) -> URL {
      project.appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("hooks", isDirectory: true)
    }

    func readSettings(at url: URL) throws -> [String: Any] {
      let data = try Data(contentsOf: url)
      return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func preEntries(in settings: [String: Any]) -> [[String: Any]] {
      let hooks = settings["hooks"] as? [String: Any] ?? [:]
      return (hooks["PreToolUse"] as? [[String: Any]]) ?? []
    }

    func hasAgentHubEntry(in entries: [[String: Any]], scriptPath: String) -> Bool {
      let quoted = ClaudeHookInstaller.shellQuoted(scriptPath)
      return entries.contains { entry in
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains {
          let cmd = $0["command"] as? String
          return cmd == scriptPath || cmd == quoted
        }
      }
    }
  }

  // MARK: - Tests

  @Test("sync installs shared script and settings entry pointing at it")
  func syncInstallsSharedScriptAndSettings() async throws {
    let fx = try Fixture(name: "syncInstalls")
    defer { fx.teardown() }

    await fx.installer.syncInstalledPaths([fx.projectA.path])

    #expect(FileManager.default.fileExists(atPath: fx.sharedScriptURL.path))

    let settings = try fx.readSettings(at: fx.settingsLocal(for: fx.projectA))
    let entries = fx.preEntries(in: settings)
    #expect(fx.hasAgentHubEntry(in: entries, scriptPath: fx.sharedScriptURL.path))
  }

  @Test("sync never writes into {project}/.claude/hooks/")
  func syncNeverWritesInProjectHooks() async throws {
    let fx = try Fixture(name: "noProjectHooks")
    defer { fx.teardown() }

    await fx.installer.syncInstalledPaths([fx.projectA.path])

    #expect(!FileManager.default.fileExists(atPath: fx.projectHooksDir(for: fx.projectA).path))
  }

  @Test("sync preserves unrelated keys in settings.local.json")
  func preservesExistingKeys() async throws {
    let fx = try Fixture(name: "preservesKeys")
    defer { fx.teardown() }

    let existing: [String: Any] = [
      "permissions": ["allow": ["bash"]],
      "env": ["FOO": "bar"],
      "hooks": [
        "PreToolUse": [
          ["matcher": "Bash", "hooks": [["type": "command", "command": "/user/other.sh"]]]
        ]
      ],
    ]
    try FileManager.default.createDirectory(
      at: fx.settingsLocal(for: fx.projectA).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: existing).write(to: fx.settingsLocal(for: fx.projectA))

    await fx.installer.syncInstalledPaths([fx.projectA.path])

    let updated = try fx.readSettings(at: fx.settingsLocal(for: fx.projectA))
    #expect(updated["env"] as? [String: String] == ["FOO": "bar"])
    #expect((updated["permissions"] as? [String: Any])?["allow"] as? [String] == ["bash"])
    let entries = fx.preEntries(in: updated)
    let userEntry = entries.first { entry in
      let inner = entry["hooks"] as? [[String: Any]] ?? []
      return inner.contains { ($0["command"] as? String) == "/user/other.sh" }
    }
    #expect(userEntry != nil)
    #expect(fx.hasAgentHubEntry(in: entries, scriptPath: fx.sharedScriptURL.path))
  }

  @Test("sync is idempotent — same input twice produces no duplicate entries")
  func idempotent() async throws {
    let fx = try Fixture(name: "idempotent")
    defer { fx.teardown() }

    await fx.installer.syncInstalledPaths([fx.projectA.path])
    await fx.installer.syncInstalledPaths([fx.projectA.path])

    let settings = try fx.readSettings(at: fx.settingsLocal(for: fx.projectA))
    let entries = fx.preEntries(in: settings)
    let quoted = ClaudeHookInstaller.shellQuoted(fx.sharedScriptURL.path)
    let matches = entries.filter { entry in
      let inner = entry["hooks"] as? [[String: Any]] ?? []
      return inner.contains {
        let cmd = $0["command"] as? String
        return cmd == fx.sharedScriptURL.path || cmd == quoted
      }
    }
    #expect(matches.count == 1)
  }

  @Test("sync removes entries from paths that dropped out of the set")
  func syncRemovesDroppedPaths() async throws {
    let fx = try Fixture(name: "removesDropped")
    defer { fx.teardown() }

    await fx.installer.syncInstalledPaths([fx.projectA.path, fx.projectB.path])
    #expect(FileManager.default.fileExists(atPath: fx.settingsLocal(for: fx.projectA).path))
    #expect(FileManager.default.fileExists(atPath: fx.settingsLocal(for: fx.projectB).path))

    await fx.installer.syncInstalledPaths([fx.projectA.path])

    let a = try fx.readSettings(at: fx.settingsLocal(for: fx.projectA))
    #expect(fx.hasAgentHubEntry(in: fx.preEntries(in: a), scriptPath: fx.sharedScriptURL.path))

    let bURL = fx.settingsLocal(for: fx.projectB)
    if FileManager.default.fileExists(atPath: bURL.path) {
      let b = try fx.readSettings(at: bURL)
      #expect(!fx.hasAgentHubEntry(in: fx.preEntries(in: b), scriptPath: fx.sharedScriptURL.path))
    }
  }

  @Test("uninstall preserves unrelated user hooks")
  func uninstallPreservesOthers() async throws {
    let fx = try Fixture(name: "uninstallPreserves")
    defer { fx.teardown() }

    let existing: [String: Any] = [
      "env": ["HELLO": "world"],
      "hooks": [
        "PreToolUse": [
          ["matcher": "Bash", "hooks": [["type": "command", "command": "/user/other.sh"]]]
        ]
      ],
    ]
    try FileManager.default.createDirectory(
      at: fx.settingsLocal(for: fx.projectA).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: existing).write(to: fx.settingsLocal(for: fx.projectA))

    await fx.installer.syncInstalledPaths([fx.projectA.path])
    await fx.installer.syncInstalledPaths([])

    let after = try fx.readSettings(at: fx.settingsLocal(for: fx.projectA))
    #expect(after["env"] as? [String: String] == ["HELLO": "world"])
    let entries = fx.preEntries(in: after)
    #expect(entries.count == 1)
    let inner = entries.first?["hooks"] as? [[String: Any]] ?? []
    #expect(inner.first?["command"] as? String == "/user/other.sh")
  }

  @Test("flushAll removes every installed entry")
  func flushAll() async throws {
    let fx = try Fixture(name: "flushAll")
    defer { fx.teardown() }

    await fx.installer.syncInstalledPaths([fx.projectA.path, fx.projectB.path])
    await fx.installer.flushAll()

    for project in [fx.projectA, fx.projectB] {
      let url = fx.settingsLocal(for: project)
      if FileManager.default.fileExists(atPath: url.path) {
        let settings = try fx.readSettings(at: url)
        #expect(!fx.hasAgentHubEntry(in: fx.preEntries(in: settings), scriptPath: fx.sharedScriptURL.path))
      }
    }
  }

  @Test("reconcileOnLaunch uninstalls previously-installed paths not in expected")
  func reconcileSweepsOrphans() async throws {
    let fx = try Fixture(name: "reconcileOrphans")
    defer { fx.teardown() }

    await fx.installer.syncInstalledPaths([fx.projectA.path])
    #expect(FileManager.default.fileExists(atPath: fx.settingsLocal(for: fx.projectA).path))

    await fx.installer.reconcileOnLaunch(expectedPaths: [])

    let url = fx.settingsLocal(for: fx.projectA)
    if FileManager.default.fileExists(atPath: url.path) {
      let settings = try fx.readSettings(at: url)
      #expect(!fx.hasAgentHubEntry(in: fx.preEntries(in: settings), scriptPath: fx.sharedScriptURL.path))
    }
  }

  @Test("written command is shell-quoted so /bin/sh -c doesn't word-split on spaces in the path")
  func writtenCommandIsShellQuoted() async throws {
    let fx = try Fixture(name: "shellQuoted")
    defer { fx.teardown() }

    await fx.installer.syncInstalledPaths([fx.projectA.path])

    let settings = try fx.readSettings(at: fx.settingsLocal(for: fx.projectA))
    let entries = fx.preEntries(in: settings)
    let inner = entries.first?["hooks"] as? [[String: Any]] ?? []
    let cmd = inner.first?["command"] as? String
    #expect(cmd == ClaudeHookInstaller.shellQuoted(fx.sharedScriptURL.path))
    #expect(cmd?.hasPrefix("'") == true)
    #expect(cmd?.hasSuffix("'") == true)
  }

  @Test("sync replaces a legacy unquoted entry with the quoted form")
  func syncReplacesLegacyUnquotedEntry() async throws {
    let fx = try Fixture(name: "migrateUnquoted")
    defer { fx.teardown() }

    let legacy: [String: Any] = [
      "hooks": [
        "PreToolUse": [
          ["matcher": "*", "hooks": [["type": "command", "command": fx.sharedScriptURL.path]]]
        ]
      ],
    ]
    try FileManager.default.createDirectory(
      at: fx.settingsLocal(for: fx.projectA).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: legacy).write(to: fx.settingsLocal(for: fx.projectA))

    await fx.installer.syncInstalledPaths([fx.projectA.path])

    let entries = fx.preEntries(in: try fx.readSettings(at: fx.settingsLocal(for: fx.projectA)))
    #expect(entries.count == 1)
    let cmd = (entries.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
    #expect(cmd == ClaudeHookInstaller.shellQuoted(fx.sharedScriptURL.path))
  }

  @Test("uninstall removes a legacy unquoted entry")
  func uninstallRemovesLegacyUnquotedEntry() async throws {
    let fx = try Fixture(name: "uninstallUnquoted")
    defer { fx.teardown() }

    let legacy: [String: Any] = [
      "hooks": [
        "PreToolUse": [
          ["matcher": "*", "hooks": [["type": "command", "command": fx.sharedScriptURL.path]]]
        ],
        "PostToolUse": [
          ["matcher": "*", "hooks": [["type": "command", "command": fx.sharedScriptURL.path]]]
        ],
      ],
    ]
    try FileManager.default.createDirectory(
      at: fx.settingsLocal(for: fx.projectA).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: legacy).write(to: fx.settingsLocal(for: fx.projectA))
    // Pretend installer had previously written this path so uninstall sees it.
    fx.defaults.set([fx.projectA.path], forKey: ClaudeHookInstaller.installedPathsKey)

    await fx.installer.syncInstalledPaths([])

    let url = fx.settingsLocal(for: fx.projectA)
    if FileManager.default.fileExists(atPath: url.path) {
      let settings = try fx.readSettings(at: url)
      #expect(!fx.hasAgentHubEntry(in: fx.preEntries(in: settings), scriptPath: fx.sharedScriptURL.path))
    }
  }

  @Test("disabled installer sweeps and installs nothing")
  func disabledIsNoop() async throws {
    let fx = try Fixture(name: "disabled")
    defer { fx.teardown() }

    await fx.installer.syncInstalledPaths([fx.projectA.path])
    await fx.installer.setEnabled(false)
    await fx.installer.syncInstalledPaths([fx.projectA.path])

    let url = fx.settingsLocal(for: fx.projectA)
    if FileManager.default.fileExists(atPath: url.path) {
      let settings = try fx.readSettings(at: url)
      #expect(!fx.hasAgentHubEntry(in: fx.preEntries(in: settings), scriptPath: fx.sharedScriptURL.path))
    }
  }
}
