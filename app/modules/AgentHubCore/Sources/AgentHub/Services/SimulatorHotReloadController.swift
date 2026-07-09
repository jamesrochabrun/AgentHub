//
//  SimulatorHotReloadController.swift
//  AgentHub
//
//  Glue between the simulator panel and the hot-reload machinery in the
//  SimulatorPreview module. Owns one launch's worth of state: the pill's
//  HotReloadMonitor, the host-side source watcher, the console tail that
//  feeds injection-engine events, and the preview-host client used by the
//  Previews tab.
//
//  Launch flow: `preparePlan` arms a launch from cached support artifacts
//  (kicking a background build of them on first use — the pill reports
//  "preparing" honestly instead of blocking Build & Run for minutes), the
//  panel passes the plan to `SimulatorService.buildAndRunOnSimulator`, and
//  `sessionDidLaunch` starts the watchers. Structural changes and failed
//  injections trigger `rebuildExecutor` — an incremental rebuild + relaunch
//  with the same plan.
//

import CryptoKit
import Foundation
import SimulatorPreview

@MainActor
@Observable
public final class SimulatorHotReloadController {

  /// State machine behind the pill; the Previews tab also re-renders on its
  /// `reloadGeneration`.
  public let monitor = HotReloadMonitor()

  /// Client for the Previews tab (talks to the inserted preview-host dylib).
  public let previewClient: any PreviewHostClientProtocol

  /// Bumped every time a launch inserts the preview host. The Previews tab
  /// uses this to retry manifest loading after auto-arm/relaunch, even if no
  /// source file has hot-reloaded yet.
  public private(set) var previewHostGeneration = 0

  /// The plan used for the current/last launch — nil before the first
  /// hot-reload launch.
  public private(set) var activePlan: HotReloadLaunchPlan?

  /// Source file names edited in this project, most recent first. This is
  /// populated only while preview observation is enabled and seeded from
  /// `git status` so files the agent edited before the panel opened count
  /// too. Drives the previews spotlight.
  public private(set) var changedSourceFiles: [String] = []

  /// Runs the fallback incremental rebuild + relaunch. Injected so tests
  /// don't shell out; defaults to `SimulatorService`.
  public var rebuildExecutor:
    (_ udid: String, _ projectPath: String, _ plan: HotReloadLaunchPlan) async -> Bool

  /// Asked to Build & Run when auto-run observation sees a source change while
  /// no injection-armed launch can hot-swap it. Returns whether the request
  /// was accepted; a `false` (build already in flight, no destination yet)
  /// re-schedules the attempt so the change isn't lost.
  public var onRequestAutoRun: (@MainActor () -> Bool)?

  private let artifactStore: any HotReloadArtifactProviding
  private let sourceWatcher: any HotReloadSourceWatching
  private let consoleTail: any HotReloadConsoleTailing
  private let consoleParser = HotReloadConsoleParser()
  private let seedChangedFiles: @Sendable (String) async -> [String]
  private let autoRunDebounce: Duration
  private var activeContext: (udid: String, projectPath: String)?
  private var preparationTask: Task<Void, Never>?
  private var isRebuilding = false
  private var isPreviewObservationEnabled = false
  private var isInjectionObservationEnabled = false
  private var isAutoRunObservationEnabled = false
  private var isSourceObservationActive = false
  private var observedProjectPath: String?
  private var hasPendingAutoRun = false
  private var autoRunDebounceTask: Task<Void, Never>?

  public init(
    artifactStore: any HotReloadArtifactProviding = HotReloadArtifactStore(),
    sourceWatcher: any HotReloadSourceWatching = HotReloadSourceWatcher(),
    consoleTail: any HotReloadConsoleTailing = HotReloadConsoleTail(),
    previewClient: any PreviewHostClientProtocol = PreviewHostHTTPClient(),
    seedChangedFiles: @escaping @Sendable (String) async -> [String] = {
      await GitChangedSwiftFiles.changedFiles(inProjectAt: $0)
    },
    rebuildExecutor: (
      (String, String, HotReloadLaunchPlan) async -> Bool
    )? = nil,
    autoRunDebounce: Duration = .seconds(2)
  ) {
    self.artifactStore = artifactStore
    self.sourceWatcher = sourceWatcher
    self.consoleTail = consoleTail
    self.previewClient = previewClient
    self.seedChangedFiles = seedChangedFiles
    self.autoRunDebounce = autoRunDebounce
    self.rebuildExecutor = rebuildExecutor ?? { udid, projectPath, plan in
      // Panel-scoped rebuilds relaunch behind the mirror; keep the real
      // Simulator.app window from stealing focus when the user hides it.
      let hideRealSimulator = UserDefaults.standard.object(
        forKey: AgentHubDefaults.simulatorHideSimulatorAppWhileMirroring
      ) as? Bool ?? true
      return await SimulatorService.shared.buildAndRunOnSimulator(
        udid: udid, projectPath: projectPath, hotReload: plan,
        foregroundSimulatorApp: !hideRealSimulator)
    }
  }

  // MARK: - Change tracking (panel lifetime)

  /// Enables preview candidate observation. Call when the Previews feature
  /// is enabled in settings — this lets the spotlight show a preview the
  /// moment the host becomes reachable, even for edits made before any
  /// launch was armed.
  public func setPreviewObservationEnabled(_ enabled: Bool, projectPath: String) {
    guard isPreviewObservationEnabled != enabled || observedProjectPath != projectPath else {
      return
    }
    isPreviewObservationEnabled = enabled
    if enabled {
      updateSourceObservation(projectPath: projectPath)
      seedPreviewCandidates(projectPath: projectPath)
    } else {
      changedSourceFiles = []
      updateSourceObservation(projectPath: activeContext?.projectPath ?? observedProjectPath)
    }
  }

  /// Compatibility wrapper for tests and older call sites.
  public func startTracking(projectPath: String) {
    setPreviewObservationEnabled(true, projectPath: projectPath)
  }

  /// Enables auto Build & Run: while no injection-armed launch can hot-swap
  /// saved files, any Swift source change debounces into `onRequestAutoRun`
  /// so agent edits reach the simulator without the user pressing anything.
  public func setAutoRunEnabled(_ enabled: Bool, projectPath: String) {
    guard isAutoRunObservationEnabled != enabled || observedProjectPath != projectPath else {
      return
    }
    isAutoRunObservationEnabled = enabled
    if enabled {
      updateSourceObservation(projectPath: projectPath)
    } else {
      autoRunDebounceTask?.cancel()
      autoRunDebounceTask = nil
      hasPendingAutoRun = false
      updateSourceObservation(projectPath: activeContext?.projectPath ?? observedProjectPath)
    }
  }

  /// Disables preview candidate observation. Call when the panel closes or
  /// when the Previews setting is turned off.
  public func stopTracking() {
    isPreviewObservationEnabled = false
    changedSourceFiles = []
    updateSourceObservation(projectPath: activeContext?.projectPath ?? observedProjectPath)
  }

  /// Most-recent-first, deduplicated, bounded.
  private func noteChangedSource(_ fileName: String) {
    guard fileName.hasSuffix(".swift") else { return }
    changedSourceFiles.removeAll { $0 == fileName }
    changedSourceFiles.insert(fileName, at: 0)
    if changedSourceFiles.count > 30 {
      changedSourceFiles.removeLast(changedSourceFiles.count - 30)
    }
  }

  // MARK: - Launch lifecycle

  /// Builds the support dylibs in the background so they're cached by the
  /// time the user hits Build & Run. Call when the panel opens.
  public func warmUp() {
    guard preparationTask == nil else { return }
    preparationTask = Task { [artifactStore] in
      _ = try? await artifactStore.prepareArtifacts(progress: nil)
    }
  }

  /// Returns the launch plan for Build & Run, or nil when neither feature is
  /// enabled or the support artifacts aren't ready yet. Never blocks on the
  /// first-run support build — it reports `.preparing` and lets the launch
  /// proceed without hot reload; the next run arms it.
  public func preparePlan(
    udid: String,
    projectPath: String,
    enableInjection: Bool,
    enablePreviews: Bool
  ) async -> HotReloadLaunchPlan? {
    guard enableInjection || enablePreviews else {
      monitor.markDisabled()
      return nil
    }

    guard let artifacts = await artifactStore.cachedArtifacts() else {
      monitor.markPreparing(
        detail: "Building hot-reload support libraries — arms on the next run")
      preparationTask = nil
      warmUp()
      Task { [weak self] in
        await self?.preparationTask?.value
        guard let self, case .preparing = self.monitor.phase else { return }
        if await self.artifactStore.cachedArtifacts() != nil {
          self.monitor.markUnavailable(
            reason: "Hot reload is ready — Build & Run again to arm it")
        } else {
          self.monitor.markUnavailable(
            reason: "Hot-reload support build failed; see logs")
        }
      }
      return nil
    }

    let configuration = HotReloadLaunchConfiguration(
      projectPath: projectPath,
      artifacts: artifacts,
      enableInjection: enableInjection,
      enablePreviews: enablePreviews
    )
    guard configuration.isEffective else {
      monitor.markUnavailable(reason: "Hot-reload support libraries unavailable")
      return nil
    }
    let wantsConsole = enableInjection && artifacts.injectionDylibPath != nil
    var consolePath: String?
    if wantsConsole {
      consolePath = Self.consoleLogPath(projectPath: projectPath, udid: udid)
      // Drop the previous launch's log so the tail can't replay stale
      // injection events into the fresh monitor.
      if let consolePath {
        try? FileManager.default.removeItem(atPath: consolePath)
      }
    }
    return HotReloadLaunchPlan(
      configuration: configuration,
      consoleStdoutPath: consolePath
    )
  }

  /// Arms the monitor + console tail after a successful hot-reload launch.
  /// (Source-change tracking runs independently — see `startTracking`.)
  public func sessionDidLaunch(
    udid: String, projectPath: String, plan: HotReloadLaunchPlan
  ) {
    consoleTail.stop()
    monitor.onRequestRebuild = nil
    activePlan = plan
    activeContext = (udid, projectPath)
    if plan.configuration.enablePreviews,
       plan.configuration.artifacts.previewHostDylibPath != nil {
      previewHostGeneration += 1
    }

    guard plan.configuration.enableInjection,
          plan.configuration.artifacts.injectionDylibPath != nil
    else {
      // Previews-only launch: the pill stays off, the tab works.
      isInjectionObservationEnabled = false
      updateSourceObservation(projectPath: projectPath)
      monitor.markDisabled()
      return
    }

    isInjectionObservationEnabled = true
    updateSourceObservation(projectPath: projectPath)
    monitor.arm()
    monitor.onRequestRebuild = { [weak self] reason in
      self?.performRebuild(reason: reason)
    }
    if let consolePath = plan.consoleStdoutPath {
      consoleTail.start(path: consolePath, onLine: makeConsoleLineHandler())
    }
  }

  /// Stops the armed launch's console + monitor (device shut down, device
  /// switched). Change tracking keeps running for the panel's lifetime.
  public func sessionDidStop() {
    consoleTail.stop()
    monitor.onRequestRebuild = nil
    activePlan = nil
    activeContext = nil
    isInjectionObservationEnabled = false
    updateSourceObservation(projectPath: observedProjectPath)
    monitor.markDisabled()
  }

  /// Console lines feed the pill's state machine, and recompile events also
  /// count as changed files (covers saves the host-side watcher misses).
  private func makeConsoleLineHandler() -> (String) -> Void {
    { [weak self] line in
      guard let self, let event = self.consoleParser.parse(line: line) else { return }
      if case .recompiling(let fileName) = event {
        if self.isPreviewObservationEnabled {
          self.noteChangedSource(fileName)
        }
      }
      self.monitor.handle(engineEvent: event)
    }
  }

  // MARK: - Internals

  private func updateSourceObservation(projectPath: String?) {
    let shouldObserve = isPreviewObservationEnabled
      || isInjectionObservationEnabled
      || isAutoRunObservationEnabled
    guard shouldObserve, let projectPath else {
      if isSourceObservationActive {
        sourceWatcher.stop()
        isSourceObservationActive = false
      }
      if !shouldObserve {
        observedProjectPath = nil
      }
      return
    }

    if isSourceObservationActive, observedProjectPath == projectPath {
      return
    }

    if isSourceObservationActive {
      sourceWatcher.stop()
    }

    observedProjectPath = projectPath
    isSourceObservationActive = true
    sourceWatcher.start(projectPath: projectPath) { [weak self] changes in
      guard let self else { return }
      if self.isPreviewObservationEnabled {
        for change in changes {
          self.noteChangedSource((change.path as NSString).lastPathComponent)
        }
      }
      if self.isInjectionObservationEnabled {
        self.monitor.handle(sourceChanges: changes)
      } else if self.isAutoRunObservationEnabled, !changes.isEmpty {
        // No armed launch can hot-swap this save — debounce into a full
        // Build & Run so the change still reaches the simulator hands-free.
        self.scheduleAutoRun()
      }
    }
  }

  private func scheduleAutoRun() {
    hasPendingAutoRun = true
    autoRunDebounceTask?.cancel()
    autoRunDebounceTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: self.autoRunDebounce)
      guard !Task.isCancelled else { return }
      self.fireAutoRunIfPending()
    }
  }

  private func fireAutoRunIfPending() {
    guard hasPendingAutoRun, isAutoRunObservationEnabled else { return }
    // An injection-armed launch appeared while we debounced — it owns the
    // change now (hot swap or structural rebuild), so drop the pending run.
    guard !isInjectionObservationEnabled else {
      hasPendingAutoRun = false
      return
    }
    guard let onRequestAutoRun else {
      hasPendingAutoRun = false
      return
    }
    if onRequestAutoRun() {
      hasPendingAutoRun = false
    } else {
      // Busy (a build mid-flight) or no destination yet — try again after
      // another debounce interval rather than dropping the change.
      autoRunDebounceTask?.cancel()
      autoRunDebounceTask = Task { [weak self] in
        guard let self else { return }
        try? await Task.sleep(for: self.autoRunDebounce)
        guard !Task.isCancelled else { return }
        self.fireAutoRunIfPending()
      }
    }
  }

  private func seedPreviewCandidates(projectPath: String) {
    Task { [weak self, seedChangedFiles] in
      let seeded = await seedChangedFiles(projectPath)
      guard let self, self.isPreviewObservationEnabled else { return }
      for fileName in seeded where !self.changedSourceFiles.contains(fileName) {
        // Seeds are older than anything observed live — append, not insert.
        self.changedSourceFiles.append(fileName)
      }
    }
  }

  private func performRebuild(reason: String) {
    guard let context = activeContext, let plan = activePlan, !isRebuilding
    else { return }
    isRebuilding = true
    monitor.markRebuildStarted(reason: reason)
    Task { [weak self] in
      guard let self else { return }
      let success = await self.rebuildExecutor(
        context.udid, context.projectPath, plan)
      self.isRebuilding = false
      if success, let consolePath = plan.consoleStdoutPath {
        // The relaunch truncated the console log; restart the tail so its
        // byte offset starts over from the new launch's first line.
        self.consoleTail.start(
          path: consolePath, onLine: self.makeConsoleLineHandler())
      }
      self.monitor.markRebuildFinished(
        success: success,
        message: success ? nil : "Rebuild failed — see the build error in the panel"
      )
    }
  }

  /// Console logs live next to the support artifacts, keyed by project+device.
  static func consoleLogPath(projectPath: String, udid: String) -> String {
    let digest = SHA256.hash(data: Data("\(projectPath)|\(udid)".utf8))
      .prefix(8)
      .map { String(format: "%02x", $0) }
      .joined()
    let directory = HotReloadArtifactStore.defaultRootDirectory
      .appendingPathComponent("console", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(digest).log").path
  }
}
