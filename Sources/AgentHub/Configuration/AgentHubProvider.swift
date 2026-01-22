//
//  AgentHubProvider.swift
//  AgentHub
//
//  Central service provider for AgentHub
//

import Foundation
import ClaudeCodeSDK
import os

/// Central service provider that manages all AgentHub services
///
/// `AgentHubProvider` provides lazy initialization of services and a single
/// factory for `ClaudeCodeClient` instances. Use this instead of manually
/// creating and wiring services.
///
/// ## Example
/// ```swift
/// @State private var provider = AgentHubProvider()
///
/// var body: some Scene {
///   WindowGroup {
///     AgentHubSessionsView()
///       .agentHub(provider)
///   }
/// }
/// ```
@MainActor
public final class AgentHubProvider {

  // MARK: - Configuration

  /// The configuration used by this provider
  public let configuration: AgentHubConfiguration

  // MARK: - Lazy Services

  /// Monitor service for tracking CLI sessions
  public private(set) lazy var monitorService: CLISessionMonitorService = {
    CLISessionMonitorService(claudeDataPath: configuration.claudeDataPath)
  }()

  /// Git worktree service for branch/worktree operations
  public private(set) lazy var gitService: GitWorktreeService = {
    GitWorktreeService()
  }()

  /// Global stats service for usage metrics
  public private(set) lazy var statsService: GlobalStatsService = {
    GlobalStatsService(claudePath: configuration.claudeDataPath)
  }()

  /// Display settings for stats visualization
  public private(set) lazy var displaySettings: StatsDisplaySettings = {
    StatsDisplaySettings(configuration.statsDisplayMode)
  }()

  /// Claude Code client for SDK communication
  public private(set) lazy var claudeClient: (any ClaudeCode)? = {
    createClaudeClient()
  }()

  // MARK: - View Models

  /// Sessions view model - created lazily and cached
  public private(set) lazy var sessionsViewModel: CLISessionsViewModel = {
    CLISessionsViewModel(
      monitorService: monitorService,
      claudeClient: claudeClient
    )
  }()

  /// Intelligence view model - created lazily and cached
  public private(set) lazy var intelligenceViewModel: IntelligenceViewModel = {
    IntelligenceViewModel(
      claudeClient: claudeClient,
      gitService: gitService,
      monitorService: monitorService
    )
  }()

  // MARK: - Initialization

  /// Creates a provider with the specified configuration
  /// - Parameter configuration: Configuration for services. Defaults to `.default`
  public init(configuration: AgentHubConfiguration = .default) {
    self.configuration = configuration
  }

  /// Creates a provider with default configuration
  public convenience init() {
    self.init(configuration: .default)
  }

  // MARK: - Claude Client Factory

  /// Creates a configured ClaudeCodeClient instance
  /// - Returns: A configured client, or nil if creation fails
  private func createClaudeClient() -> (any ClaudeCode)? {
    do {
      var config = ClaudeCodeConfiguration.withNvmSupport()
      config.enableDebugLogging = configuration.enableDebugLogging

      let homeDir = NSHomeDirectory()

      // Add local Claude installation path (highest priority)
      let localClaudePath = "\(homeDir)/.claude/local"
      if FileManager.default.fileExists(atPath: localClaudePath) {
        config.additionalPaths.insert(localClaudePath, at: 0)
      }

      // Add configured additional paths
      for path in configuration.additionalCLIPaths {
        if !config.additionalPaths.contains(path) {
          config.additionalPaths.append(path)
        }
      }

      // Add common development tool paths
      let defaultPaths = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "\(homeDir)/.bun/bin",
        "\(homeDir)/.deno/bin",
        "\(homeDir)/.cargo/bin",
        "\(homeDir)/.local/bin"
      ]

      for path in defaultPaths {
        if !config.additionalPaths.contains(path) {
          config.additionalPaths.append(path)
        }
      }

      return try ClaudeCodeClient(configuration: config)
    } catch {
      AppLogger.session.error("Failed to create ClaudeCodeClient: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Public Factory Methods

  /// Creates a new Claude client with the provider's configuration
  /// - Returns: A new ClaudeCodeClient, or nil if creation fails
  ///
  /// Use this when you need a fresh client instance rather than the shared one.
  public func makeClaudeClient() -> (any ClaudeCode)? {
    createClaudeClient()
  }

  // MARK: - App Lifecycle

  /// Cleans up orphaned Claude processes from previous runs.
  /// Call this on app launch to terminate any Claude processes that were orphaned
  /// when the app crashed or was force-quit.
  public func cleanupOrphanedProcesses() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-eo", "pid,ppid,command"]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()

    do {
      try task.run()
      task.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      guard let output = String(data: data, encoding: .utf8) else { return }

      for line in output.components(separatedBy: .newlines) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              ppid == 1 else { continue }

        // Check if it's a Claude process (orphaned processes have PPID=1)
        let command = String(parts[2])
        if command.contains("claude") || command.contains("Claude") {
          AppLogger.session.warning("Killing orphaned Claude process PID=\(pid)")
          kill(pid, SIGTERM)
        }
      }
    } catch {
      AppLogger.session.error("Failed to find orphaned processes: \(error.localizedDescription)")
    }
  }

  /// Terminates all active terminal processes.
  /// Call this on app termination to clean up all running Claude sessions.
  public func terminateAllTerminals() {
    for (key, terminal) in sessionsViewModel.activeTerminals {
      AppLogger.session.info("Terminating terminal for key: \(key)")
      terminal.terminateProcess()
    }
  }
}
