import AgentHubCLIKit
import Combine
import Foundation

// MARK: - WorktreeProgressSidecarWatcherProtocol

/// Watches the `worktree-progress/` sidecar directory that the `agenthub` CLI
/// writes while it performs `git worktree add` for MCP-initiated creations.
/// Emits the latest `WorktreeProgressSnapshot` for each operation so the app
/// can surface live progress even though the work happens in another process.
public protocol WorktreeProgressSidecarWatcherProtocol: AnyObject, Sendable {
  var updates: AnyPublisher<WorktreeProgressSnapshot, Never> { get }
  /// Begins watching the directory and emits any snapshots already on disk.
  func start() async
  /// Removes every progress file and drops all in-memory state. Called at
  /// launch so a snapshot left behind by a creation that finished while
  /// AgentHub was down can't be replayed as a fake in-flight operation.
  func wipeAll() async
  /// Deletes the sidecar file for a finished operation once the coordinator has
  /// shown its terminal state. Owned by the coordinator's clearing policy.
  func discardSnapshot(operationID: String) async
}

// MARK: - WorktreeProgressSidecarWatcher

/// kqueue-based watcher mirroring `ClaudeHookSidecarWatcher`'s structure, with
/// one deliberate difference: the CLI writes each snapshot via an **atomic
/// temp-then-move** (see `WorktreeProgressQueue.write`), which changes the
/// file's inode on every update. A per-file `O_EVTONLY` fd opened on the old
/// inode goes stale after the first move, so we rely on the **directory**
/// source — it fires on every rename-into-directory — and re-scan + decode all
/// files on each event. Snapshots are whole-file overwrites, so we dedupe by
/// `Equatable` value per operation rather than tracking byte offsets.
public actor WorktreeProgressSidecarWatcher: WorktreeProgressSidecarWatcherProtocol {

  private let queue: WorktreeProgressQueue
  private let fileManager: FileManager
  private nonisolated let subject = PassthroughSubject<WorktreeProgressSnapshot, Never>()
  private nonisolated let processingQueue = DispatchQueue(label: "com.agenthub.worktree-progress.sidecar")

  private var directorySource: DispatchSourceFileSystemObject?
  private var lastEmitted: [String: WorktreeProgressSnapshot] = [:]
  private var started = false

  public nonisolated var updates: AnyPublisher<WorktreeProgressSnapshot, Never> {
    subject.eraseToAnyPublisher()
  }

  public init(
    queue: WorktreeProgressQueue = WorktreeProgressQueue(),
    fileManager: FileManager = .default
  ) {
    self.queue = queue
    self.fileManager = fileManager
  }

  // MARK: - Public API

  public func start() async {
    guard !started else { return }
    started = true
    ensureDirectory()
    startDirectorySourceIfNeeded()
    // Emit anything already on disk (a creation may have started before we
    // attached the source).
    scanAndEmit()
  }

  public func wipeAll() async {
    directorySource?.cancel()
    directorySource = nil
    started = false
    lastEmitted.removeAll()
    try? queue.wipeAll()
    ensureDirectory()
  }

  public func discardSnapshot(operationID: String) async {
    lastEmitted.removeValue(forKey: operationID)
    try? queue.remove(operationID: operationID)
  }

  // MARK: - Internals

  private func ensureDirectory() {
    try? fileManager.createDirectory(at: queue.directoryURL, withIntermediateDirectories: true)
  }

  private func startDirectorySourceIfNeeded() {
    guard directorySource == nil else { return }
    let fd = open(queue.directoryURL.path, O_EVTONLY)
    guard fd >= 0 else {
      AppLogger.watcher.error("[WorktreeProgress] Could not open progress dir: \(self.queue.directoryURL.path)")
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .rename, .delete],
      queue: processingQueue
    )
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.scanAndEmit() }
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    directorySource = source
  }

  /// Re-reads every snapshot file and emits the ones whose value changed since
  /// the last emission, ignoring snapshots older than the last seen for the
  /// same operation (progress callbacks can arrive slightly out of order).
  private func scanAndEmit() {
    let snapshots: [WorktreeProgressSnapshot]
    do {
      snapshots = try queue.pendingSnapshots()
    } catch {
      AppLogger.watcher.error("[WorktreeProgress] Failed to read snapshots: \(error.localizedDescription)")
      return
    }

    for snapshot in snapshots {
      if let previous = lastEmitted[snapshot.operationID] {
        if previous == snapshot { continue }
        if snapshot.updatedAt < previous.updatedAt { continue }
      }
      lastEmitted[snapshot.operationID] = snapshot
      subject.send(snapshot)
    }
  }

  deinit {
    directorySource?.cancel()
  }
}
