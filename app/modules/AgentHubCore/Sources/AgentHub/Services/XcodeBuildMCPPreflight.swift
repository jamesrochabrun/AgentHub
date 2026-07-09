//
//  XcodeBuildMCPPreflight.swift
//  AgentHub
//
//  Preflight for the XcodeBuildMCP bootstrap: the server launch script needs
//  either a globally installed `xcodebuildmcp` binary or `npx` (Node) to fetch
//  the pinned release. When neither is reachable the bootstrap is skipped so
//  agents aren't told to use simulator tools that can never connect.
//

import Foundation
import UserNotifications

public enum XcodeBuildMCPPreflight {

  /// Directories the MCP launch script prepends to PATH before resolving
  /// `xcodebuildmcp`/`npx`. Kept in sync with `xcodeBuildMCPShellScript()`.
  static let standardSearchDirectories = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin"
  ]

  /// Whether the user has the XcodeBuildMCP bootstrap enabled (default on).
  public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: AgentHubDefaults.xcodeBuildMCPEnabled) as? Bool ?? true
  }

  /// Whether the launch script can resolve a way to run XcodeBuildMCP: a
  /// global `xcodebuildmcp` binary, `npx` on the search path, or an
  /// nvm-managed Node install (the script sources nvm before falling back).
  public static func nodeToolingAvailable(
    searchPaths: [String]? = nil,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) -> Bool {
    let directories = searchPaths ?? defaultSearchPaths()
    for directory in directories {
      for executable in ["xcodebuildmcp", "npx"] {
        let candidate = (directory as NSString).appendingPathComponent(executable)
        if fileManager.isExecutableFile(atPath: candidate) {
          return true
        }
      }
    }
    return nvmManagedNPXExists(homeDirectory: homeDirectory, fileManager: fileManager)
  }

  private static func defaultSearchPaths() -> [String] {
    var paths = standardSearchDirectories
    paths += CLIPathResolver.executableSearchPaths(additionalPaths: [])
    if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
      paths += environmentPath.split(separator: ":").map(String.init)
    }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  private static func nvmManagedNPXExists(
    homeDirectory: URL,
    fileManager: FileManager
  ) -> Bool {
    let nodeVersionsDirectory = homeDirectory
      .appendingPathComponent(".nvm/versions/node", isDirectory: true)
    guard let versions = try? fileManager.contentsOfDirectory(
      at: nodeVersionsDirectory,
      includingPropertiesForKeys: nil
    ) else {
      return false
    }
    return versions.contains { version in
      fileManager.isExecutableFile(
        atPath: version.appendingPathComponent("bin/npx").path
      )
    }
  }
}

/// One-shot user-facing notice when an Xcode-project session launches without
/// Node tooling: the session still starts, just without simulator tools.
@MainActor
public enum XcodeBuildMCPNodeNotice {
  private static var hasNotified = false

  public static func notifyOnce() {
    guard !hasNotified else { return }
    hasNotified = true
    guard UserDefaults.standard.object(
      forKey: AgentHubDefaults.pushNotificationsEnabled
    ) as? Bool ?? true else { return }

    let content = UNMutableNotificationContent()
    content.title = "Simulator tools unavailable"
    content.body = "Install Node.js to enable XcodeBuildMCP simulator automation in agent sessions."
    content.sound = .none

    let request = UNNotificationRequest(
      identifier: "xcodebuildmcp-node-missing",
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    )
    Task {
      // Best-effort: silently drop if notifications aren't authorized.
      try? await UNUserNotificationCenter.current().add(request)
    }
  }
}
