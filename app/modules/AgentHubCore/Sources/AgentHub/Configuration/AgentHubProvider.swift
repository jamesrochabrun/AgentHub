//
//  AgentHubProvider.swift
//  AgentHub
//
//  Central service provider for AgentHub
//

import AgentHubGitHub
import AgentHubGitDiff
import AgentHubCLIKit
import SimulatorPreview
import Foundation
import os
import ClaudeCodeClient

#if canImport(AppKit)
import AppKit
#endif

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
  public let terminalBackend: EmbeddedTerminalBackend

  /// Factory used to construct embedded terminal surfaces for the chosen backend.
  /// The app target injects a Ghostty-aware factory; tests and standalone uses
  /// of `AgentHubCore` get the default factory which falls back to the regular
  /// SwiftTerm surface when `.ghostty` is selected.
  public let terminalSurfaceFactory: any EmbeddedTerminalSurfaceFactory
  private let globalSessionControlPanelPresenterFactory: GlobalSessionControlPanelPresenterFactory
  private let metadataStoreOverride: SessionMetadataStore?
  private let worktreeLaunchRequestMonitorOverride: (any WorktreeLaunchRequestMonitorProtocol)?
  private let worktreeDeletionRequestMonitorOverride: (any WorktreeDeletionRequestMonitorProtocol)?

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

  /// Claude file watcher for real-time monitoring. Wired to the approval hook
  /// sidecar so pending-approval state can be surfaced while Claude Code CLI
  /// buffers its JSONL writes.
  private lazy var claudeFileWatcher: SessionFileWatcher = {
    SessionFileWatcher(
      claudePath: configuration.claudeDataPath,
      hookSidecarWatcher: claudeHookSidecarWatcher
    )
  }()

  /// Shared claim store gating the approval hook script.
  public private(set) lazy var approvalClaimStore: any ApprovalClaimStoreProtocol = {
    ApprovalClaimStore()
  }()

  /// Watches the approval sidecar directory populated by the installed hook.
  public private(set) lazy var claudeHookSidecarWatcher: any ClaudeHookSidecarWatcherProtocol = {
    ClaudeHookSidecarWatcher()
  }()

  /// Installs/uninstalls the AgentHub approval hook per worktree.
  public private(set) lazy var claudeHookInstaller: any ClaudeHookInstallerProtocol = {
    guard let metadataStore else {
      AppLogger.session.error("[ClaudeHook] SessionMetadataStore unavailable; approval hook installation disabled")
      return NoOpClaudeHookInstaller()
    }
    return ClaudeHookInstaller(stateStore: metadataStore)
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

  /// Cached project-level detector for web preview button visibility.
  lazy var webPreviewCandidateService: any WebPreviewCandidateServiceProtocol = {
    WebPreviewCandidateService.shared
  }()

  /// Discovers and routes MCP App UI resources exposed by configured MCP servers.
  public private(set) lazy var mcpAppDiscoveryService: any MCPAppDiscoveryServiceProtocol = {
    MCPAppDiscoveryService.shared
  }()

  /// Cached project-level detector for inline diff tab visibility.
  lazy var diffAvailabilityService: any DiffAvailabilityServiceProtocol = {
    DiffAvailabilityService.shared
  }()

  /// Live in-app iOS Simulator capture/streaming. All capture stays in-process;
  /// no network, no Screen Recording/Accessibility permissions. See the
  /// `SimulatorPreview` module README for the privacy contract.
  public private(set) lazy var simulatorStreamService: any SimulatorStreamServiceProtocol = {
    SimulatorStreamService.shared
  }()

  /// Session metadata store for user-provided session names
  public private(set) lazy var metadataStore: SessionMetadataStore? = {
    if let metadataStoreOverride {
      return metadataStoreOverride
    }
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

  /// Shared `claude -p` invocation service used by short, non-interactive
  /// callers (branch naming, inline-edit style reconciliation, etc.).
  public private(set) lazy var programmaticClaudeService: any ClaudeProgrammaticServiceProtocol = {
    ClaudeProgrammaticService(
      additionalPaths: ClaudeCodePathResolver.searchPaths(additionalPaths: configuration.additionalCLIPaths)
    )
  }()

  /// Claude-backed service for naming launcher-generated worktree branches.
  public private(set) lazy var worktreeBranchNamingService: any WorktreeBranchNamingServiceProtocol = {
    ClaudeWorktreeBranchNamingService(programmaticService: programmaticClaudeService)
  }()

  /// Claude-backed local audit of AgentHub's current session/worktree state.
  public private(set) lazy var sessionInvestigationService: any SessionInvestigationServiceProtocol = {
    ClaudeSessionInvestigationService(programmaticService: programmaticClaudeService)
  }()

  /// Reformats Canvas inline-toolbar edits so the persisted file matches the
  /// project's existing code style. Runs Haiku via `claude -p` after the
  /// debounced direct write so the UX stays snappy.
  public private(set) lazy var inlineEditReconciler: any InlineEditStyleReconcilerProtocol = {
    ClaudeInlineEditStyleReconciler(programmaticService: programmaticClaudeService)
  }()

  /// Success sound service for completed launcher-created worktrees.
  public private(set) lazy var worktreeSuccessSoundService: any WorktreeSuccessSoundServiceProtocol = {
    WorktreeSuccessSoundService()
  }()

  /// Watches requests written by the bundled `agenthub` helper.
  public private(set) lazy var worktreeLaunchRequestMonitor: any WorktreeLaunchRequestMonitorProtocol = {
    worktreeLaunchRequestMonitorOverride ?? WorktreeLaunchRequestMonitor()
  }()

  /// Watches worktree deletion cleanup requests written by the bundled `agenthub` helper.
  public private(set) lazy var worktreeDeletionRequestMonitor: any WorktreeDeletionRequestMonitorProtocol = {
    worktreeDeletionRequestMonitorOverride ?? WorktreeDeletionRequestMonitor()
  }()

  public private(set) lazy var worktreeLaunchRequestHandler: any WorktreeLaunchRequestHandlingProtocol = {
    WorktreeLaunchRequestHandler(
      claudeViewModel: claudeSessionsViewModel,
      codexViewModel: codexSessionsViewModel
    )
  }()

  public private(set) lazy var worktreeDeletionRequestHandler: any WorktreeDeletionRequestHandlingProtocol = {
    WorktreeDeletionRequestHandler(
      claudeViewModel: claudeSessionsViewModel,
      codexViewModel: codexSessionsViewModel
    )
  }()

  /// Watches the worktree-progress sidecar directory the `agenthub` CLI writes
  /// during MCP-initiated creations, so the app can surface live git progress.
  public private(set) lazy var worktreeProgressSidecarWatcher: any WorktreeProgressSidecarWatcherProtocol = {
    WorktreeProgressSidecarWatcher()
  }()

  /// Posts the "worktrees ready" macOS notification when a batch completes.
  public private(set) lazy var worktreeReadyNotificationService: any WorktreeReadyNotificationServiceProtocol = {
    WorktreeReadyNotificationService()
  }()

  /// App-wide coordinator unifying worktree creation progress (side panel + MCP)
  /// for the top bar; fires the completion sound/notification once per batch.
  public private(set) lazy var worktreeGenerationProgressCoordinator: WorktreeGenerationProgressCoordinator = {
    WorktreeGenerationProgressCoordinator(
      soundService: worktreeSuccessSoundService,
      notificationService: worktreeReadyNotificationService
    )
  }()

  private var isWorktreeLaunchRequestMonitoringStarted = false
  private var isWorktreeDeletionRequestMonitoringStarted = false
  private var isWorktreeProgressMonitoringStarted = false

  // MARK: - GitHub Integration

  /// GitHub CLI service for PR/issue operations
  public private(set) lazy var gitHubService: any GitHubCLIServiceProtocol = {
    GitHubCLIService()
  }()

  /// Shared session-card GitHub quick access coordinator
  public private(set) lazy var gitHubQuickAccessCoordinator: any SessionGitHubQuickAccessCoordinatorProtocol = {
    SessionGitHubQuickAccessCoordinator(service: gitHubService)
  }()

  /// Shared GitHub PR/check observation service for panels and session rows
  public private(set) lazy var gitHubPRObservationService: any GitHubPRObservationServiceProtocol = {
    GitHubPRObservationService(service: gitHubService)
  }()

  // MARK: - Global Session Control Panel

  /// Routes global-panel session selections into the main sessions UI.
  public private(set) lazy var globalSessionSelectionRouter: GlobalSessionSelectionRouter = {
    GlobalSessionSelectionRouter()
  }()

  /// Coordinates the opt-in global hotkey and floating sessions panel.
  public private(set) lazy var globalSessionControlPanelCoordinator: GlobalSessionControlPanelCoordinator = {
    GlobalSessionControlPanelCoordinator(provider: self)
  }()

  public func makeGlobalSessionControlPanelPresenter(
    defaults: UserDefaults = .standard
  ) -> any GlobalSessionControlPanelPresenting {
    globalSessionControlPanelPresenterFactory(self, defaults)
  }

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
  /// - Parameters:
  ///   - configuration: Configuration for services. Defaults to `.default`
  ///   - terminalSurfaceFactory: Optional factory override. Defaults to a
  ///     parameterless `DefaultEmbeddedTerminalSurfaceFactory()` which falls
  ///     back to the regular backend when `.ghostty` is selected. The app
  ///     target should pass a Ghostty-aware factory.
  public init(
    configuration: AgentHubConfiguration = .default,
    terminalSurfaceFactory: any EmbeddedTerminalSurfaceFactory = DefaultEmbeddedTerminalSurfaceFactory(),
    globalSessionControlPanelPresenterFactory: @escaping GlobalSessionControlPanelPresenterFactory = { _, _ in
      NoOpGlobalSessionControlPanelPresenter()
    },
    metadataStore: SessionMetadataStore? = nil,
    worktreeLaunchRequestMonitor: (any WorktreeLaunchRequestMonitorProtocol)? = nil,
    worktreeDeletionRequestMonitor: (any WorktreeDeletionRequestMonitorProtocol)? = nil
  ) {
    self.configuration = configuration
    self.terminalBackend = .storedPreference
    self.terminalSurfaceFactory = terminalSurfaceFactory
    self.globalSessionControlPanelPresenterFactory = globalSessionControlPanelPresenterFactory
    self.metadataStoreOverride = metadataStore
    self.worktreeLaunchRequestMonitorOverride = worktreeLaunchRequestMonitor
    self.worktreeDeletionRequestMonitorOverride = worktreeDeletionRequestMonitor
    if let metadataStore {
      Task {
        await TerminalProcessRegistry.shared.configure(store: metadataStore)
      }
    }

    // Persist developer-provided commands to UserDefaults
    let defaults = UserDefaults.standard
    defaults.register(defaults: [
      AgentHubDefaults.globalSessionPanelEnabled: true,
      AgentHubDefaults.globalSessionPanelDisplayMode: 0
    ])

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
      environmentOverridesProvider: { CLIEnvironmentOverrides.environment },
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
      let claudeArgString = defaults.string(forKey: AgentHubDefaults.claudeCommandArgs) ?? ""
      cliConfiguration = CLICommandConfiguration(
        command: command,
        additionalPaths: ClaudeCodePathResolver.searchPaths(additionalPaths: configuration.additionalCLIPaths),
        mode: .claude,
        extraArgs: CLICommandConfiguration.parseArgumentString(claudeArgString)
      )
    case .codex:
      let userCommand = defaults.string(forKey: AgentHubDefaults.codexCommand) ?? configuration.codexCommand
      let codexArgString = defaults.string(forKey: AgentHubDefaults.codexCommandArgs) ?? ""
      // Store the user's configured command string as-is (e.g. "agenthub codex")
      // Executable resolution happens at launch time using executableName
      cliConfiguration = CLICommandConfiguration(
        command: userCommand,
        additionalPaths: CLIPathResolver.codexPaths(additionalPaths: configuration.additionalCLIPaths),
        mode: .codex,
        extraArgs: CLICommandConfiguration.parseArgumentString(codexArgString)
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

    // Claude sessions get the approval hook services wired in. Codex sessions
    // pass nil (no Codex hook equivalent exists today — see plan).
    let claimStore: (any ApprovalClaimStoreProtocol)? = providerKind == .claude ? approvalClaimStore : nil
    let installer: (any ClaudeHookInstallerProtocol)? = providerKind == .claude ? claudeHookInstaller : nil

    let vm = CLISessionsViewModel(
      monitorService: selectedMonitor,
      fileWatcher: selectedWatcher,
      searchService: selectedSearch,
      cliConfiguration: cliConfiguration,
      providerKind: providerKind,
      metadataStore: metadataStore,
      webPreviewCandidateService: webPreviewCandidateService,
      mcpAppDiscoveryService: mcpAppDiscoveryService,
      diffAvailabilityService: diffAvailabilityService,
      approvalClaimStore: claimStore,
      hookInstaller: installer,
      codexDataPath: providerKind == .codex ? configuration.codexDataPath : nil,
      terminalSurfaceFactory: terminalSurfaceFactory,
      terminalBackend: terminalBackend,
      terminalWorkspaceStore: metadataStore
    )
    vm.agentHubProvider = self
    return vm
  }

  // MARK: - App Lifecycle

  /// Cleans up orphaned Claude processes from previous runs.
  /// Call this on app launch to terminate any Claude processes that were orphaned
  /// when the app crashed or was force-quit.
  public func cleanupOrphanedProcesses() {
    Task(priority: .utility) {
      await TerminalProcessRegistry.shared.cleanupRegisteredProcesses()
    }
  }

  public func shutdownMCPAppDiscoveryService() {
    let service = mcpAppDiscoveryService
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .utility) {
      await service.shutdown()
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2.0)
  }

  public func startWorktreeLaunchRequestMonitoring() {
    startWorktreeLaunchQueueMonitoring()
    startWorktreeDeletionQueueMonitoring()
    startWorktreeProgressMonitoring()
  }

  private func startWorktreeProgressMonitoring() {
    guard !isWorktreeProgressMonitoringStarted else { return }
    isWorktreeProgressMonitoringStarted = true

    let watcher = worktreeProgressSidecarWatcher
    // Subscribe before starting the watcher so we don't miss its initial scan.
    worktreeGenerationProgressCoordinator.startObservingMCP(watcher: watcher)
    let notifications = worktreeReadyNotificationService
    Task {
      // Drop snapshots left behind by a creation that finished while the app
      // was down, then begin watching for live progress.
      await watcher.wipeAll()
      await watcher.start()
      await notifications.requestPermission()
    }
  }

  private func startWorktreeLaunchQueueMonitoring() {
    guard !isWorktreeLaunchRequestMonitoringStarted else { return }
    isWorktreeLaunchRequestMonitoringStarted = true

    let monitor = worktreeLaunchRequestMonitor
    Task {
      await monitor.start { [weak self] queued in
        guard let self else {
          throw WorktreeLaunchRequestHandlingError.providerUnavailable
        }
        try await self.worktreeLaunchRequestHandler.handle(queued.request)
      }
    }
  }

  private func startWorktreeDeletionQueueMonitoring() {
    guard !isWorktreeDeletionRequestMonitoringStarted else { return }
    isWorktreeDeletionRequestMonitoringStarted = true

    let monitor = worktreeDeletionRequestMonitor
    Task {
      await monitor.start { [weak self] queued in
        guard let self else {
          throw WorktreeDeletionRequestHandlingError.deletionFailed("AgentHub provider is unavailable.")
        }
        try await self.worktreeDeletionRequestHandler.handle(queued.request)
      }
    }
  }

  public func stopWorktreeLaunchRequestMonitoring() {
    if isWorktreeLaunchRequestMonitoringStarted {
      isWorktreeLaunchRequestMonitoringStarted = false

      let monitor = worktreeLaunchRequestMonitor
      Task {
        await monitor.stop()
      }
    }

    if isWorktreeDeletionRequestMonitoringStarted {
      isWorktreeDeletionRequestMonitoringStarted = false

      let monitor = worktreeDeletionRequestMonitor
      Task {
        await monitor.stop()
      }
    }
  }

  /// Sweeps any previously-installed approval hooks, wipes stale claim files,
  /// and drops stale approval sidecar files. Call this on app launch before
  /// sessions start restoring.
  ///
  /// **Blocks** the calling thread until cleanup completes. This is
  /// deliberate: the lazy `claudeSessionsViewModel` triggers
  /// `setupSubscriptions`, which can fire `syncInstalledPaths` on first
  /// repository emission. If the reconcile is still in flight at that point,
  /// the sync can install freshly and then the late-arriving reconcile sweeps
  /// those same paths back out as "stale", leaving approval hooks unregistered
  /// until the next repository change. Blocking here removes the race.
  public func reconcileClaudeHooksOnLaunch(timeout: TimeInterval = 3.0) {
    let claimStore = approvalClaimStore
    let installer = claudeHookInstaller
    let sidecar = claudeHookSidecarWatcher
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
      async let resetClaims: Void = claimStore.resetAll()
      async let wipeSidecars: Void = sidecar.wipeAll()
      async let reconcileHooks: Void = installer.reconcileOnLaunch(expectedPaths: [])
      _ = await (resetClaims, wipeSidecars, reconcileHooks)
      semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
      AppLogger.session.error("[ClaudeHook] reconcileClaudeHooksOnLaunch timed out after \(timeout)s — first session sync may race")
    }
  }

  /// Removes every approval hook we've installed and releases claims. Call
  /// from `NSApplicationDelegate.applicationWillTerminate` so external Claude
  /// Code runs after quit see no trace of AgentHub.
  ///
  /// This method **blocks** the calling thread until the cleanup completes
  /// (or `timeout` elapses). `applicationWillTerminate` is the last hook AppKit
  /// offers before the process is killed, so an unstructured `Task` spawned
  /// here will be torn down mid-flight and leave stale hook entries in
  /// `settings.local.json` plus stray claim files behind. Filesystem ops are
  /// fast (<100ms for a typical install set); a 3-second cap guards against
  /// deadlock without punishing normal quits.
  public func flushClaudeHooksOnTerminate(timeout: TimeInterval = 3.0) {
    let claimStore = approvalClaimStore
    let installer = claudeHookInstaller
    let sidecar = claudeHookSidecarWatcher
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
      async let flushHooks: Void = installer.flushAll()
      async let resetClaims: Void = claimStore.resetAll()
      async let wipeSidecars: Void = sidecar.wipeAll()
      _ = await (flushHooks, resetClaims, wipeSidecars)
      semaphore.signal()
    }
    let deadline = DispatchTime.now() + timeout
    if semaphore.wait(timeout: deadline) == .timedOut {
      AppLogger.session.error("[ClaudeHook] flushClaudeHooksOnTerminate timed out after \(timeout)s — shutdown may leave stale hook state behind")
    }
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

  public func recreateEmbeddedTerminalsForSelectedBackend() {
    AppLogger.session.info("Terminal backend changes require app restart; keeping existing terminals alive")
  }

  public func relaunchApplication() {
    #if canImport(AppKit)
    let bundlePath = Bundle.main.bundlePath
    let escapedBundlePath = shellEscapedPath(bundlePath)
    let script = "sleep 1; /usr/bin/open -n \(escapedBundlePath)"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]

    do {
      try process.run()
      NSApplication.shared.terminate(nil)
    } catch {
      AppLogger.session.error("Failed to relaunch AgentHub: \(error.localizedDescription)")
    }
    #else
    AppLogger.session.error("Relaunch is unavailable outside AppKit")
    #endif
  }

  private func shellEscapedPath(_ path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
