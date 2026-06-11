import Foundation
import Observation

/// State machine behind the hot-reload pill for one (project, device) launch.
///
/// Inputs come from two sides: host-side source-change events (the
/// `HotReloadSourceWatcher`) flip the pill to "Reloading…" the moment a file
/// is saved, and engine events parsed from the app's console confirm the
/// hot-swap (or report that it failed). Structural changes and failed
/// injections quietly fall back to an incremental rebuild via
/// `onRequestRebuild`, with the pill showing "Rebuilding…" — the pill never
/// pretends a change was applied when it wasn't.
@MainActor
@Observable
public final class HotReloadMonitor {

  public private(set) var phase: HotReloadPhase = .disabled

  /// Bumped every time the running app's code actually changed (successful
  /// injection or completed rebuild). The previews spotlight re-renders on
  /// this. (Changed-file tracking lives in `SimulatorHotReloadController`,
  /// panel-lifetime — it must survive re-arming.)
  public private(set) var reloadGeneration = 0

  /// Latest non-fatal engine diagnostic, surfaced in the pill tooltip.
  public private(set) var lastWarning: String?

  /// Asked to run an incremental rebuild + relaunch. The owner must call
  /// `markRebuildFinished` when it completes.
  public var onRequestRebuild: ((_ reason: String) -> Void)?

  /// How long "Reloaded" lingers before settling back to idle.
  public var settleDelay: TimeInterval = 2.5
  /// How long a save may sit in "Reloading…" without engine confirmation
  /// before we assume the change can't be hot-swapped.
  public var reloadTimeout: TimeInterval = 12
  /// Whether failed/timed-out injections automatically trigger a rebuild.
  public var automaticRebuildFallback = true

  private var settleTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?

  public init() {}

  // MARK: - Lifecycle

  public func markDisabled() {
    cancelTimers()
    phase = .disabled
  }

  public func markPreparing(detail: String) {
    cancelTimers()
    phase = .preparing(detail: detail)
  }

  public func markUnavailable(reason: String) {
    cancelTimers()
    phase = .unavailable(reason: reason)
  }

  /// The app was launched with the injection dylib inserted.
  public func arm() {
    cancelTimers()
    lastWarning = nil
    phase = .idle
  }

  // MARK: - Source changes (host-side watcher)

  public func handle(sourceChanges: [HotReloadSourceChange]) {
    guard isArmed else { return }

    if let structural = sourceChanges.first(where: {
      if case .structural = $0 { return true } else { return false }
    }), case .structural(let path, let kind) = structural {
      let file = (path as NSString).lastPathComponent
      requestRebuild(reason: "\(file) was \(kind.rawValue)")
      return
    }

    guard case .rebuilding = phase else {
      if let change = sourceChanges.last {
        let file = (change.path as NSString).lastPathComponent
        beginReloading(fileName: file)
      }
      return
    }
  }

  // MARK: - Engine events (console)

  public func handle(engineEvent: HotReloadEngineEvent) {
    switch engineEvent {
    case .engineReady:
      if case .preparing = phase { phase = .idle }
      if case .disabled = phase { phase = .idle }

    case .recompiling(let fileName):
      guard isArmed else { return }
      beginReloading(fileName: fileName)

    case .injected(let summary):
      guard isArmed else { return }
      cancelTimers()
      reloadGeneration += 1
      phase = .reloaded(summary: summary)
      scheduleSettle()

    case .injectionFailed(let message):
      guard isArmed else { return }
      cancelTimers()
      if automaticRebuildFallback {
        requestRebuild(reason: message)
      } else {
        phase = .failed(message: message)
      }

    case .warning(let message):
      lastWarning = message
    }
  }

  // MARK: - Rebuild fallback

  public func markRebuildStarted(reason: String) {
    cancelTimers()
    phase = .rebuilding(reason: reason)
  }

  public func markRebuildFinished(success: Bool, message: String? = nil) {
    cancelTimers()
    if success {
      reloadGeneration += 1
      phase = .idle
    } else {
      phase = .failed(message: message ?? "Rebuild failed")
    }
  }

  // MARK: - Internals

  private var isArmed: Bool {
    switch phase {
    case .disabled, .preparing, .unavailable:
      return false
    case .idle, .reloading, .reloaded, .rebuilding, .failed:
      return true
    }
  }

  private func beginReloading(fileName: String) {
    if case .rebuilding = phase { return }
    phase = .reloading(fileName: fileName)
    scheduleReloadTimeout()
  }

  private func requestRebuild(reason: String) {
    if case .rebuilding = phase { return }
    cancelTimers()
    phase = .rebuilding(reason: reason)
    onRequestRebuild?(reason)
  }

  private func scheduleSettle() {
    settleTask?.cancel()
    let delay = settleDelay
    settleTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      if case .reloaded = self.phase { self.phase = .idle }
    }
  }

  private func scheduleReloadTimeout() {
    timeoutTask?.cancel()
    let timeout = reloadTimeout
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      guard case .reloading = self.phase else { return }
      if self.automaticRebuildFallback {
        self.requestRebuild(reason: "Change didn't hot-swap")
      } else {
        self.phase = .failed(message: "Change didn't hot-swap")
      }
    }
  }

  private func cancelTimers() {
    settleTask?.cancel()
    settleTask = nil
    timeoutTask?.cancel()
    timeoutTask = nil
  }
}
