import AgentHubCLIKit
import Foundation

public protocol SessionNameRequestMonitorProtocol: AnyObject, Sendable {
  func start(handler: @escaping @MainActor @Sendable (QueuedSessionNameRequest) async throws -> Void) async
  func stop() async
}

public actor SessionNameRequestMonitor: SessionNameRequestMonitorProtocol {
  private let queue: SessionNameRequestQueue
  private let pollInterval: Duration
  private var task: Task<Void, Never>?
  private var activeRequestIds: Set<String> = []

  public init(
    queue: SessionNameRequestQueue = SessionNameRequestQueue(),
    pollInterval: Duration = .seconds(1)
  ) {
    self.queue = queue
    self.pollInterval = pollInterval
  }

  public func start(
    handler: @escaping @MainActor @Sendable (QueuedSessionNameRequest) async throws -> Void
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
    queue: SessionNameRequestQueue,
    handler: @escaping @MainActor @Sendable (QueuedSessionNameRequest) async throws -> Void
  ) async {
    let queuedRequests: [QueuedSessionNameRequest]
    do {
      queuedRequests = try queue.pendingRequests()
    } catch {
      AppLogger.session.error("Failed to read AgentHub session name requests: \(error.localizedDescription)")
      return
    }

    for queued in queuedRequests {
      guard activeRequestIds.insert(queued.request.id).inserted else { continue }
      defer { activeRequestIds.remove(queued.request.id) }

      do {
        try await handler(queued)
        try queue.remove(queued)
      } catch {
        AppLogger.session.error("Failed to handle AgentHub session name request: \(error.localizedDescription)")
        do {
          try queue.markFailed(queued)
        } catch {
          AppLogger.session.error("Failed to mark AgentHub session name request failed: \(error.localizedDescription)")
        }
      }
    }
  }
}
