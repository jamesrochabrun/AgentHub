//
//  AgentHubProvider.swift
//  AgentHub
//
//  Central service provider for AgentHub
//

import Foundation
import os
import ClaudeCodeClient

/// Central service provider that manages all AgentHub services
///
/// `AgentHubProvider` provides lazy initialization of services and a single
/// factory for creating CLI process services. Use this instead of manually
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
    CLISessionMonitorService(claudeDataPath: configuration.claudeDataPath, metadataStore: metadataStore)
  }()

  /// Monitor service for tracking Codex sessions
  public private(set) lazy var codexMonitorService: CodexSessionMonitorService = {
    CodexSessionMonitorService(codexDataPath: configuration.codexDataPath, metadataStore: metadataStore)
  }()

  /// Git worktree service for branch/worktree operations
  public private(set) lazy var gitService: GitWorktreeService = {
    GitWorktreeService()
  }()

  /// Global stats service for Claude usage metrics
  public private(set) lazy var statsService: GlobalStatsService = {
    GlobalStatsService(claudePath: configuration.claudeDataPath)
  }()

  /// Global stats service for Codex usage metrics
  public private(set) lazy var codexStatsService: CodexGlobalStatsService = {
    CodexGlobalStatsService(codexPath: configuration.codexDataPath)
  }()

  /// Codex file watcher for real-time monitoring
  private lazy var codexFileWatcher: CodexSessionFileWatcher = {
    CodexSessionFileWatcher(codexPath: configuration.codexDataPath)
  }()

  /// Claude file watcher for real-time monitoring
  private lazy var claudeFileWatcher: SessionFileWatcher = {
    SessionFileWatcher(claudePath: configuration.claudeDataPath)
  }()

  /// Claude search service
  private lazy var claudeSearchService: GlobalSearchService = {
    GlobalSearchService(claudeDataPath: configuration.claudeDataPath)
  }()

  /// Codex search service
  private lazy var codexSearchService: CodexSearchService = {
    CodexSearchService(codexDataPath: configuration.codexDataPath)
  }()

  /// Display settings for stats visualization
  public private(set) lazy var displaySettings: StatsDisplaySettings = {
    StatsDisplaySettings(configuration.statsDisplayMode)
  }()

  /// Session metadata store for user-provided session names
  public private(set) lazy var metadataStore: SessionMetadataStore? = {
    do {
      return try SessionMetadataStore()
    } catch {
      AppLogger.session.error("Failed to create SessionMetadataStore: \(error.localizedDescription)")
      return nil
    }
  }()

  /// AI configuration service for provider-specific session defaults
  public private(set) lazy var aiConfigService: (any AIConfigServiceProtocol)? = {
    guard let store = metadataStore else { return nil }
    return AIConfigService(metadataStore: store)
  }()

  // MARK: - GitHub Integration

  /// GitHub CLI service for PR/issue operations
  public private(set) lazy var gitHubService: any GitHubCLIServiceProtocol = {
    GitHubCLIService()
  }()

  /// Shared session-card GitHub quick access coordinator
  public private(set) lazy var gitHubQuickAccessCoordinator: any SessionGitHubQuickAccessCoordinatorProtocol = {
    SessionGitHubQuickAccessCoordinator(service: gitHubService)
  }()

  // MARK: - Theme Management

  /// Theme manager for YAML and built-in themes
  public private(set) lazy var themeManager: ThemeManager = {
    ThemeManager()
  }()

  // MARK: - View Models

  /// Claude sessions view model - created lazily and cached
  public private(set) lazy var claudeSessionsViewModel: CLISessionsViewModel = {
    makeSessionsViewModel(providerKind: .claude)
  }()

  /// Codex sessions view model - created lazily and cached
  public private(set) lazy var codexSessionsViewModel: CLISessionsViewModel = {
    makeSessionsViewModel(providerKind: .codex)
  }()

  /// Backwards-compatible default sessions view model (Claude)
  public private(set) lazy var sessionsViewModel: CLISessionsViewModel = {
    claudeSessionsViewModel
  }()

  /// Intelligence view model - created lazily and cached
  public private(set) lazy var intelligenceViewModel: IntelligenceViewModel = {
    IntelligenceViewModel(processService: createProcessService())
  }()

  // MARK: - Initialization

  /// Creates a provider with the specified configuration
  /// - Parameter configuration: Configuration for services. Defaults to `.default`
  public init(configuration: AgentHubConfiguration = .default) {
    self.configuration = configuration

    // Persist developer-provided commands to UserDefaults
    let defaults = UserDefaults.standard

    // Claude command: if developer provided non-default, lock it
    if configuration.cliCommand != "claude" {
      defaults.set(configuration.cliCommand, forKey: AgentHubDefaults.claudeCommand)
      defaults.set(true, forKey: AgentHubDefaults.claudeCommandLockedByDeveloper)
    } else if defaults.string(forKey: AgentHubDefaults.claudeCommand) == nil {
      // Set default if not already set by user
      defaults.set("claude", forKey: AgentHubDefaults.claudeCommand)
    }

    // Codex command: same logic
    if configuration.codexCommand != "codex" {
      defaults.set(configuration.codexCommand, forKey: AgentHubDefaults.codexCommand)
      defaults.set(true, forKey: AgentHubDefaults.codexCommandLockedByDeveloper)
    } else if defaults.string(forKey: AgentHubDefaults.codexCommand) == nil {
      defaults.set("codex", forKey: AgentHubDefaults.codexCommand)
    }
  }

  /// Creates a provider with default configuration
  public convenience init() {
    self.init(configuration: .default)
  }

  // MARK: - CLI Process Service Factory

  /// Creates a Claude CLI client with paths resolved from configuration.
  private func createProcessService() -> any ClaudeCLIClientProtocol {
    let debugLogger: (@Sendable (String) -> Void)?
    if configuration.enableDebugLogging {
      debugLogger = { message in
        AppLogger.intelligence.debug("\(message, privacy: .public)")
      }
    } else {
      debugLogger = nil
    }

    return ClaudeCLIClient(
      command: configuration.cliCommand,
      additionalPaths: ClaudeCodePathResolver.searchPaths(additionalPaths: configuration.additionalCLIPaths),
      debugLogger: debugLogger
    )
  }

  // MARK: - Sessions ViewModel Factory

  private func makeSessionsViewModel(providerKind: SessionProviderKind) -> CLISessionsViewModel {
    let cliConfiguration: CLICommandConfiguration
    let defaults = UserDefaults.standard
    switch providerKind {
    case .claude:
      let command = defaults.string(forKey: AgentHubDefaults.claudeCommand)
        ?? configuration.cliCommand
      cliConfiguration = CLICommandConfiguration(
        command: command,
        additionalPaths: ClaudeCodePathResolver.searchPaths(additionalPaths: configuration.additionalCLIPaths),
        mode: .claude
      )
    case .codex:
      let userCommand = defaults.string(forKey: AgentHubDefaults.codexCommand) ?? configuration.codexCommand
      // Store the user's configured command string as-is (e.g. "airchat codex")
      // Executable resolution happens at launch time using executableName
      cliConfiguration = CLICommandConfiguration(
        command: userCommand,
        additionalPaths: CLIPathResolver.codexPaths(additionalPaths: configuration.additionalCLIPaths),
        mode: .codex
      )
    }

    let selectedMonitor: any SessionMonitorServiceProtocol = {
      switch providerKind {
      case .claude: return monitorService
      case .codex: return codexMonitorService
      }
    }()

    let selectedWatcher: any SessionFileWatcherProtocol = {
      switch providerKind {
      case .claude: return claudeFileWatcher
      case .codex: return codexFileWatcher
      }
    }()

    let selectedSearch: (any SessionSearchServiceProtocol)? = {
      switch providerKind {
      case .claude: return claudeSearchService
      case .codex: return codexSearchService
      }
    }()

    let vm = CLISessionsViewModel(
      monitorService: selectedMonitor,
      fileWatcher: selectedWatcher,
      searchService: selectedSearch,
      cliConfiguration: cliConfiguration,
      providerKind: providerKind,
      metadataStore: metadataStore
    )
    vm.agentHubProvider = self
    return vm
  }

  // MARK: - App Lifecycle

  /// Cleans up orphaned Claude processes from previous runs.
  /// Call this on app launch to terminate any Claude processes that were orphaned
  /// when the app crashed or was force-quit.
  public func cleanupOrphanedProcesses() {
    TerminalProcessRegistry.shared.cleanupRegisteredProcesses()
  }

  /// Terminates all active terminal processes.
  /// Call this on app termination to clean up all running Claude sessions.
  public func terminateAllTerminals() {
    let allTerminals = claudeSessionsViewModel.managedTerminalEntries
      + codexSessionsViewModel.managedTerminalEntries

    for (key, terminal) in allTerminals {
      AppLogger.session.info("Terminating terminal for key: \(key)")
      terminal.terminateProcess()
    }
  }
}
