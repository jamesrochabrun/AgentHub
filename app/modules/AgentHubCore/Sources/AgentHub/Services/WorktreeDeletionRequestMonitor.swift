import AgentHubCLIKit
import Foundation

public protocol WorktreeDeletionRequestMonitorProtocol: AnyObject, Sendable {
  func start(handler: @escaping @MainActor @Sendable (QueuedWorktreeDeletionRequest) async throws -> Void) async
  func stop() async
}

public actor WorktreeDeletionRequestMonitor: WorktreeDeletionRequestMonitorProtocol {
  private let queue: WorktreeDeletionRequestQueue
  private let pollInterval: Duration
  private var task: Task<Void, Never>?
  private var activeRequestIds: Set<String> = []

  public init(
    queue: WorktreeDeletionRequestQueue = WorktreeDeletionRequestQueue(),
    pollInterval: Duration = .seconds(1)
  ) {
    self.queue = queue
    self.pollInterval = pollInterval
  }

  public func start(
    handler: @escaping @MainActor @Sendable (QueuedWorktreeDeletionRequest) async throws -> Void
  ) async {
    guard task == nil else { return }

    task = Task { [queue, pollInterval] in
      while !Task.isCancelled {
        await self.processPendingRequests(queue: queue, handler: handler)
        try? await Task.sleep(for: pollInterval)
      }
    }
  }

  public func stop() async {
    task?.cancel()
    task = nil
    activeRequestIds.removeAll()
  }

  private func processPendingRequests(
    queue: WorktreeDeletionRequestQueue,
    handler: @escaping @MainActor @Sendable (QueuedWorktreeDeletionRequest) async throws -> Void
  ) async {
    let queuedRequests: [QueuedWorktreeDeletionRequest]
    do {
      queuedRequests = try queue.pendingRequests()
    } catch {
      AppLogger.session.error("Failed to read AgentHub worktree deletion requests: \(error.localizedDescription)")
      return
    }

    for queued in queuedRequests {
      guard activeRequestIds.insert(queued.request.id).inserted else { continue }
      defer { activeRequestIds.remove(queued.request.id) }

      do {
        try await handler(queued)
        try queue.remove(queued)
      } catch {
        AppLogger.session.error("Failed to handle AgentHub worktree deletion request: \(error.localizedDescription)")
        do {
          try queue.markFailed(queued)
        } catch {
          AppLogger.session.error("Failed to mark AgentHub worktree deletion request failed: \(error.localizedDescription)")
        }
      }
    }
  }
}
