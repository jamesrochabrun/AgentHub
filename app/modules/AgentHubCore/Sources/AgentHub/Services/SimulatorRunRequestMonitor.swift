import AgentHubCLIKit
import Foundation

public protocol SimulatorRunRequestMonitorProtocol: AnyObject, Sendable {
  func start(handler: @escaping @MainActor @Sendable (QueuedSimulatorRunRequest) async throws -> Void) async
  func stop() async
}

public actor SimulatorRunRequestMonitor: SimulatorRunRequestMonitorProtocol {
  private let queue: SimulatorRunRequestQueue
  private let pollInterval: Duration
  private var task: Task<Void, Never>?
  private var activeRequestIds: Set<String> = []

  public init(
    queue: SimulatorRunRequestQueue = SimulatorRunRequestQueue(),
    pollInterval: Duration = .seconds(1)
  ) {
    self.queue = queue
    self.pollInterval = pollInterval
  }

  public func start(
    handler: @escaping @MainActor @Sendable (QueuedSimulatorRunRequest) async throws -> Void
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
    queue: SimulatorRunRequestQueue,
    handler: @escaping @MainActor @Sendable (QueuedSimulatorRunRequest) async throws -> Void
  ) async {
    let queuedRequests: [QueuedSimulatorRunRequest]
    do {
      queuedRequests = try queue.pendingRequests()
    } catch {
      AppLogger.simulator.error("Failed to read AgentHub simulator run requests: \(error.localizedDescription)")
      return
    }

    for queued in queuedRequests {
      guard activeRequestIds.insert(queued.request.id).inserted else { continue }
      defer { activeRequestIds.remove(queued.request.id) }

      do {
        try await handler(queued)
        try queue.remove(queued)
      } catch {
        AppLogger.simulator.error("Failed to handle AgentHub simulator run request: \(error.localizedDescription)")
        do {
          try queue.markFailed(queued)
        } catch {
          AppLogger.simulator.error("Failed to mark AgentHub simulator run request failed: \(error.localizedDescription)")
        }
      }
    }
  }
}
