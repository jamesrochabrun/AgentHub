//
//  WorktreeGenerationProgressCoordinator.swift
//  AgentHub
//

import AgentHubCLIKit
import Combine
import Foundation

// MARK: - WorktreeGenerationOperation

/// One tracked worktree creation, regardless of which entry point started it.
public struct WorktreeGenerationOperation: Identifiable, Equatable, Sendable {
  public enum Source: Sendable, Equatable {
    /// Created in-process from the side-panel sheet.
    case sidePanel
    /// Created by the `agenthub` CLI for an MCP tool call (progress streamed via sidecar).
    case mcp
    /// Created in-process by the Start Session / multi-session launch flow.
    case launch
  }

  public enum Kind: Sendable, Equatable {
    /// Git worktree creation (preparing → updating files → completed).
    case creation
    /// The AI branch-naming request that runs before creation. Transient: it
    /// doesn't count toward the "all ready" notification and clears quickly.
    case naming
  }

  public let id: String
  public let branchName: String
  public let repoName: String
  public let provider: SessionProviderKind
  public let source: Source
  public let kind: Kind
  public var progress: WorktreeCreationProgress
  public let startedAt: Date
  public var finishedAt: Date?

  public init(
    id: String,
    branchName: String,
    repoName: String,
    provider: SessionProviderKind,
    source: Source,
    kind: Kind = .creation,
    progress: WorktreeCreationProgress,
    startedAt: Date,
    finishedAt: Date? = nil
  ) {
    self.id = id
    self.branchName = branchName
    self.repoName = repoName
    self.provider = provider
    self.source = source
    self.kind = kind
    self.progress = progress
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  public var isFailure: Bool {
    if case .failed = progress { return true }
    return false
  }

  public var isNaming: Bool { kind == .naming }
}

// MARK: - WorktreeGenerationProgressCoordinator

/// App-wide, single source of truth for "what worktrees are being created right
/// now." Unifies the in-process side-panel path and the cross-process MCP path
/// (via `WorktreeProgressSidecarWatcher`), drives the top-bar UI, and fires a
/// single completion sound + notification when a batch finishes.
///
/// Provider-owned (one instance shared across windows) so the completion
/// sound/notification fire exactly once regardless of how many windows render
/// the top bar — the fire logic lives here, never in a per-view `onChange`.
@MainActor
@Observable
public final class WorktreeGenerationProgressCoordinator {

  // MARK: Tunables

  /// Debounce before announcing "all ready": a single MCP batch creates
  /// worktrees sequentially, so the in-flight count momentarily hits zero
  /// between them. Wait for the idle state to be stable before firing.
  static let doneDebounce: Duration = .milliseconds(750)
  static let successClearDelay: Duration = .seconds(3)
  static let failureClearDelay: Duration = .seconds(30)
  /// Naming finishes just before creation begins; keep its row briefly so the
  /// bar doesn't flicker empty during the handoff, then let creation take over.
  static let namingClearDelay: Duration = .seconds(1)

  // MARK: Observable state

  public private(set) var operations: [WorktreeGenerationOperation] = []

  // MARK: Dependencies

  private let soundService: any WorktreeSuccessSoundServiceProtocol
  private let notificationService: any WorktreeReadyNotificationServiceProtocol

  // MARK: Private state (not observed)

  @ObservationIgnored private var mcpWatcher: (any WorktreeProgressSidecarWatcherProtocol)?
  @ObservationIgnored private var mcpCancellable: AnyCancellable?
  @ObservationIgnored private var clearTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var doneDebounceTask: Task<Void, Never>?
  /// Branch names that reached `.completed` since the last "all ready" fire.
  @ObservationIgnored private var pendingReadyBranches: [String] = []

  public init(
    soundService: any WorktreeSuccessSoundServiceProtocol,
    notificationService: any WorktreeReadyNotificationServiceProtocol
  ) {
    self.soundService = soundService
    self.notificationService = notificationService
  }

  // MARK: - Derived UI state

  public var isActive: Bool { !operations.isEmpty }

  public var inFlightCount: Int {
    operations.filter { $0.progress.isInProgress }.count
  }

  /// Mean of all tracked operations' progress (0...1), for the collapsed bar.
  public var aggregateProgress: Double {
    guard !operations.isEmpty else { return 0 }
    let total = operations.reduce(0.0) { $0 + $1.progress.progressValue }
    return total / Double(operations.count)
  }

  public var hasFailures: Bool {
    operations.contains { $0.isFailure }
  }

  // MARK: - Side-panel entry point

  /// Begins an in-process side-panel creation. The coordinator owns the `Task`
  /// (so it survives the sheet dismissing immediately) and pipes progress into
  /// the tracked operation. `create` performs the work and receives the
  /// `onProgress` callback to forward to the underlying service.
  public func beginSidePanelOperation(
    branchName: String,
    repoName: String,
    providerKind: SessionProviderKind,
    create: @escaping @MainActor (_ onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void) async throws -> Void
  ) {
    let id = UUID().uuidString
    upsert(WorktreeGenerationOperation(
      id: id,
      branchName: branchName,
      repoName: repoName,
      provider: providerKind,
      source: .sidePanel,
      progress: .preparing(message: "Preparing worktree…"),
      startedAt: Date()
    ))

    Task {
      do {
        try await create { progress in
          await self.ingest(progress, for: id)
        }
        // Safety net: if the service returned without delivering a terminal
        // state, mark it complete so the op doesn't linger as in-flight.
        self.markCompletedIfNeeded(id: id)
      } catch {
        self.ingest(.failed(error: error.localizedDescription), for: id)
      }
    }
  }

  // MARK: - MCP entry point

  /// Subscribes to the cross-process progress watcher. Call once at startup.
  public func startObservingMCP(watcher: any WorktreeProgressSidecarWatcherProtocol) {
    guard mcpCancellable == nil else { return }
    mcpWatcher = watcher
    mcpCancellable = watcher.updates
      .receive(on: DispatchQueue.main)
      .sink { [weak self] snapshot in
        self?.ingestMCP(snapshot)
      }
  }

  private func ingestMCP(_ snapshot: WorktreeProgressSnapshot) {
    upsertProgress(
      operationID: snapshot.operationID,
      branchName: snapshot.branchName,
      repoName: URL(fileURLWithPath: snapshot.repositoryPath).lastPathComponent,
      provider: Self.providerKind(from: snapshot.provider),
      source: .mcp,
      progress: snapshot.progress,
      startedAt: snapshot.updatedAt
    )
  }

  // MARK: - Launch-flow entry point

  /// Tracks an externally-owned in-process creation (the Start Session /
  /// multi-session launch flow, which needs the worktree path back so it owns
  /// the work). Call repeatedly with progress keyed by the same `operationID`.
  public func reportLaunchProgress(
    operationID: String,
    branchName: String,
    repoName: String,
    providerKind: SessionProviderKind,
    progress: WorktreeCreationProgress
  ) {
    upsertProgress(
      operationID: operationID,
      branchName: branchName,
      repoName: repoName,
      provider: providerKind,
      source: .launch,
      progress: progress,
      startedAt: nil
    )
  }

  /// Tracks the AI branch-naming request that runs before git creation. Shown
  /// as a transient "Generating branch name…" row; never counts toward the
  /// "all ready" notification and clears quickly so creation rows take over.
  public func reportNamingProgress(
    operationID: String,
    repoName: String,
    providerKind: SessionProviderKind,
    progress: WorktreeBranchNamingProgress
  ) {
    let mapped: WorktreeCreationProgress
    switch progress {
    case .idle:
      return
    case .preparingContext(let message), .sanitizing(let message), .queryingModel(_, let message):
      mapped = .preparing(message: message.isEmpty ? "Generating branch name…" : message)
    case .completed:
      mapped = .completed(path: "")
    case .cancelled(let message):
      mapped = .cancelled(message: message)
    case .failed(let message):
      mapped = .failed(error: message)
    }
    upsertProgress(
      operationID: operationID,
      branchName: "",
      repoName: repoName,
      provider: providerKind,
      source: .launch,
      kind: .naming,
      progress: mapped,
      startedAt: nil
    )
  }

  /// Finds-or-creates an operation by id and applies the progress. Used by the
  /// MCP sidecar path, the launch-flow creation path, and branch naming.
  private func upsertProgress(
    operationID id: String,
    branchName: String,
    repoName: String,
    provider: SessionProviderKind,
    source: WorktreeGenerationOperation.Source,
    kind: WorktreeGenerationOperation.Kind = .creation,
    progress: WorktreeCreationProgress,
    startedAt: Date?
  ) {
    if operations.contains(where: { $0.id == id }) {
      ingest(progress, for: id)
    } else {
      var op = WorktreeGenerationOperation(
        id: id,
        branchName: branchName,
        repoName: repoName,
        provider: provider,
        source: source,
        kind: kind,
        progress: progress,
        startedAt: startedAt ?? Date()
      )
      if !progress.isInProgress {
        op.finishedAt = Date()
      }
      operations.append(op)
      if !progress.isInProgress {
        handleTerminal(op)
      }
      scheduleDoneCheck()
    }
  }

  // MARK: - Manual dismissal (for failed rows)

  public func dismiss(id: String) {
    clearTasks[id]?.cancel()
    clearTasks[id] = nil
    finalizeClear(id: id)
  }

  /// Clears every failed operation. Backs the header's dismiss control so a
  /// failed creation (which otherwise lingers) can be dismissed immediately —
  /// including a single failure, which doesn't expand to a per-row dismiss.
  public func dismissAllFailed() {
    for op in operations where op.isFailure {
      dismiss(id: op.id)
    }
  }

  // MARK: - Ingest / state machine

  private func ingest(_ progress: WorktreeCreationProgress, for id: String) {
    guard let idx = operations.firstIndex(where: { $0.id == id }) else { return }
    // Git stderr callbacks can arrive after the terminal sidecar snapshot; terminal states are final.
    guard operations[idx].progress.isInProgress else { return }
    guard operations[idx].progress != progress else { return }
    operations[idx].progress = progress
    if !progress.isInProgress {
      operations[idx].finishedAt = Date()
      handleTerminal(operations[idx])
    }
    scheduleDoneCheck()
  }

  private func markCompletedIfNeeded(id: String) {
    guard let idx = operations.firstIndex(where: { $0.id == id }),
          operations[idx].progress.isInProgress else { return }
    ingest(.completed(path: operations[idx].branchName), for: id)
  }

  private func handleTerminal(_ op: WorktreeGenerationOperation) {
    switch op.progress {
    case .completed:
      if op.isNaming {
        // Naming done — don't announce it as a ready worktree; clear quickly.
        scheduleClear(id: op.id, delay: Self.namingClearDelay)
      } else {
        if !pendingReadyBranches.contains(op.branchName) {
          pendingReadyBranches.append(op.branchName)
        }
        scheduleClear(id: op.id, delay: Self.successClearDelay)
      }
    case .failed:
      scheduleClear(id: op.id, delay: Self.failureClearDelay)
    case .cancelled:
      scheduleClear(id: op.id, delay: op.isNaming ? Self.namingClearDelay : Self.successClearDelay)
    case .idle, .queued, .preparing, .updatingFiles:
      break
    }
  }

  // MARK: - Grace-clear

  private func scheduleClear(id: String, delay: Duration) {
    clearTasks[id]?.cancel()
    clearTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.finalizeClear(id: id)
    }
  }

  private func finalizeClear(id: String) {
    clearTasks[id]?.cancel()
    clearTasks[id] = nil
    let wasMCP = operations.first(where: { $0.id == id })?.source == .mcp
    operations.removeAll { $0.id == id }
    if wasMCP, let watcher = mcpWatcher {
      Task { await watcher.discardSnapshot(operationID: id) }
    }
  }

  // MARK: - "All ready" detection (debounced)

  private func scheduleDoneCheck() {
    let inFlight = operations.contains { $0.progress.isInProgress }
    if inFlight {
      doneDebounceTask?.cancel()
      doneDebounceTask = nil
      return
    }
    guard !pendingReadyBranches.isEmpty else { return }
    doneDebounceTask?.cancel()
    doneDebounceTask = Task { [weak self] in
      try? await Task.sleep(for: Self.doneDebounce)
      guard !Task.isCancelled else { return }
      self?.fireDoneIfStillIdle()
    }
  }

  private func fireDoneIfStillIdle() {
    doneDebounceTask = nil
    guard !operations.contains(where: { $0.progress.isInProgress }) else { return }
    guard !pendingReadyBranches.isEmpty else { return }
    let branches = pendingReadyBranches
    pendingReadyBranches = []

    if soundsEnabled {
      let sound = soundService
      Task { await sound.playWorktreeCreatedSound() }
    }
    notificationService.notifyReady(branchNames: branches)
  }

  // MARK: - Helpers

  private func upsert(_ op: WorktreeGenerationOperation) {
    if let idx = operations.firstIndex(where: { $0.id == op.id }) {
      operations[idx] = op
    } else {
      operations.append(op)
    }
  }

  private var soundsEnabled: Bool {
    UserDefaults.standard.object(forKey: AgentHubDefaults.notificationSoundsEnabled) as? Bool ?? true
  }

  static func providerKind(from provider: WorktreeLaunchProvider) -> SessionProviderKind {
    switch provider {
    case .claude: return .claude
    case .codex: return .codex
    }
  }
}
