//
//  EmbeddedTerminalLaunch.swift
//  AgentHub
//

import Foundation

public struct EmbeddedTerminalLaunch {
  public let shellCommand: String
  public let environment: [String: String]

  public init(shellCommand: String, environment: [String: String]) {
    self.shellCommand = shellCommand
    self.environment = environment
  }

  public var swiftTermExecutable: String { "/bin/bash" }
  public var swiftTermArguments: [String] { ["-c", shellCommand] }
  public var swiftTermEnvironment: [String] {
    var swiftTermEnvironment = environment
    swiftTermEnvironment["TERM_PROGRAM"] = "SwiftTerm"
    return swiftTermEnvironment.map { "\($0.key)=\($0.value)" }
  }

  public var ghosttyCommand: String {
    "/bin/bash -c \(Self.shellEscapeSingleQuotedAllowingNewlines(shellCommand))"
  }

  public static func shellLaunch(
    projectPath: String,
    shellPath: String? = nil
  ) -> EmbeddedTerminalLaunch {
    let environment = makeProcessEnvironment()
    let shellExecutable = resolveShellExecutablePath(shellPath)
    let escapedPath = shellEscape(projectPath.isEmpty ? NSHomeDirectory() : projectPath)
    let escapedShellPath = shellEscape(shellExecutable)
    let shellCommand = "cd '\(escapedPath)' && exec '\(escapedShellPath)' -l"
    return EmbeddedTerminalLaunch(shellCommand: shellCommand, environment: environment)
  }

  private static func shellEscapeSingleQuotedAllowingNewlines(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
  }

  private static func makeProcessEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"
    environment.removeValue(forKey: "TERM_PROGRAM")

    let pathString = commonExecutableSearchPaths().joined(separator: ":")
    if let existingPath = environment["PATH"] {
      environment["PATH"] = "\(pathString):\(existingPath)"
    } else {
      environment["PATH"] = pathString
    }
    return environment
  }

  private static func commonExecutableSearchPaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
    uniquePaths([
      "\(homeDirectory)/.claude/local",
      "\(homeDirectory)/.codex/local",
      "\(homeDirectory)/.codex/bin",
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "/usr/bin",
      "\(homeDirectory)/.nvm/current/bin",
      "\(homeDirectory)/.nvm/versions/node/v22.16.0/bin",
      "\(homeDirectory)/.nvm/versions/node/v20.11.1/bin",
      "\(homeDirectory)/.nvm/versions/node/v18.19.0/bin",
      "\(homeDirectory)/.bun/bin",
      "\(homeDirectory)/.deno/bin",
      "\(homeDirectory)/.cargo/bin",
      "\(homeDirectory)/.local/bin"
    ])
  }

  private static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  private static func shellEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
  }

  private static func resolveShellExecutablePath(_ shellPath: String?) -> String {
    let candidate = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    return "/bin/zsh"
  }
}

public enum EmbeddedTerminalLaunchError: LocalizedError, Equatable {
  case executableNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let command):
      return "Could not find '\(command)' command."
    }
  }
}
