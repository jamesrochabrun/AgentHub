import Foundation

/// Detects which agent CLIs (Claude Code, Codex) are installed on the system.
public protocol AgentCLIDetecting: Sendable {
  func detectInstalledCLIs() async -> [DetectedAgentCLI]
}

/// Resolves agent CLIs by scanning the `PATH` for their executables. It performs no
/// process spawning — presence is determined purely from the filesystem — so it stays
/// fast, side-effect free, and testable with injected directories and an executable check.
public struct AgentCLIDetector: AgentCLIDetecting {
  /// Executable names searched for each provider, in priority order.
  private static let candidateExecutables: [(provider: WorktreeLaunchProvider, names: [String])] = [
    (.claude, ["claude"]),
    (.codex, ["codex"]),
  ]

  private let pathDirectories: [String]
  private let isExecutable: @Sendable (String) -> Bool

  public init(
    pathDirectories: [String]? = nil,
    isExecutable: (@Sendable (String) -> Bool)? = nil
  ) {
    self.pathDirectories = pathDirectories ?? Self.defaultPathDirectories()
    self.isExecutable = isExecutable ?? { path in
      FileManager.default.isExecutableFile(atPath: path)
    }
  }

  public func detectInstalledCLIs() async -> [DetectedAgentCLI] {
    Self.candidateExecutables.compactMap { provider, names in
      for name in names {
        if let path = resolveExecutable(named: name) {
          return DetectedAgentCLI(provider: provider, executablePath: path)
        }
      }
      return nil
    }
  }

  private func resolveExecutable(named name: String) -> String? {
    for directory in pathDirectories where !directory.isEmpty {
      let candidate = (directory as NSString).appendingPathComponent(name)
      if isExecutable(candidate) {
        return candidate
      }
    }
    return nil
  }

  private static func defaultPathDirectories() -> [String] {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var directories = path.split(separator: ":").map(String.init)
    // GUI-launched apps frequently inherit a minimal PATH; include common install
    // locations so user-installed CLIs are still found.
    let commonLocations = [
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "\(NSHomeDirectory())/.local/bin",
      "\(NSHomeDirectory())/.npm-global/bin",
      "\(NSHomeDirectory())/bin",
    ]
    for location in commonLocations where !directories.contains(location) {
      directories.append(location)
    }
    return directories
  }
}
