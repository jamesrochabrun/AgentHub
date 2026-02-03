//
//  AgentHubConfiguration.swift
//  AgentHub
//
//  Configuration for AgentHub services and providers
//

import Foundation

/// Configuration for AgentHub services
///
/// Use this to customize behavior when initializing `AgentHubProvider`.
///
/// ## Example
/// ```swift
/// var config = AgentHubConfiguration.default
/// config.enableDebugLogging = true
/// let provider = AgentHubProvider(configuration: config)
/// ```
public struct AgentHubConfiguration: Sendable {

  /// Path to Claude data directory (default: ~/.claude)
  public var claudeDataPath: String

  /// Path to Codex data directory (default: ~/.codex)
  public var codexDataPath: String

  /// Enable debug logging for troubleshooting
  public var enableDebugLogging: Bool

  /// Additional paths to search for Claude CLI
  /// These are added to the PATH when launching Claude processes
  public var additionalCLIPaths: [String]

  /// Display mode for stats (menu bar or popover)
  public var statsDisplayMode: StatsDisplayMode

  /// The CLI command name to use (default: "claude")
  /// Companies can configure this for white-labeling (e.g., "acme" instead of "claude")
  public var cliCommand: String

  /// The Codex CLI command name to use (default: "codex")
  /// Companies can configure this for white-labeling
  public var codexCommand: String

  /// Session provider to use (Claude or Codex)
  public var sessionProvider: SessionProviderKind

  /// Creates a configuration with custom values
  public init(
    claudeDataPath: String = "~/.claude",
    codexDataPath: String = "~/.codex",
    enableDebugLogging: Bool = false,
    additionalCLIPaths: [String] = [],
    statsDisplayMode: StatsDisplayMode = .menuBar,
    cliCommand: String = "claude",
    codexCommand: String = "codex",
    sessionProvider: SessionProviderKind = .claude
  ) {
    let expanded = NSString(string: claudeDataPath).expandingTildeInPath
    self.claudeDataPath = expanded
    self.codexDataPath = NSString(string: codexDataPath).expandingTildeInPath
    self.enableDebugLogging = enableDebugLogging
    self.additionalCLIPaths = additionalCLIPaths
    self.statsDisplayMode = statsDisplayMode
    self.cliCommand = cliCommand
    self.codexCommand = codexCommand
    self.sessionProvider = sessionProvider
  }

  /// Default configuration with sensible defaults
  public static var `default`: AgentHubConfiguration {
    AgentHubConfiguration()
  }

  /// Configuration with common development tool paths included
  public static var withDevPaths: AgentHubConfiguration {
    let homeDir = NSHomeDirectory()
    return AgentHubConfiguration(
      additionalCLIPaths: [
        "\(homeDir)/.claude/local",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "\(homeDir)/.bun/bin",
        "\(homeDir)/.deno/bin",
        "\(homeDir)/.cargo/bin",
        "\(homeDir)/.local/bin"
      ]
    )
  }
}
