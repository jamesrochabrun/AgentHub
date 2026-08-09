import AgentHubCLIKit
import Foundation

public protocol MeasurementRecordMonitorProtocol: AnyObject, Sendable {
  func start(handler: @escaping @MainActor @Sendable (QueuedMeasurementRecord) async throws -> Void) async
  func stop() async
}

/// Drains measurements the `agenthub` CLI queued on disk into the app.
///
/// Same shape as `SessionNameRequestMonitor`: poll the queue directory, hand
/// each record to the app, and only delete the file once the app has taken it.
/// A record whose session cannot be resolved yet is left in place and retried,
/// because the CLI can file a measurement a moment before AgentHub has bound the
/// session id.
public actor MeasurementRecordMonitor: MeasurementRecordMonitorProtocol {
  private let queue: MeasurementRecordQueue
  private let pollInterval: Duration
  private var task: Task<Void, Never>?
  private var activeRecordIds: Set<String> = []

  public init(
    queue: MeasurementRecordQueue = MeasurementRecordQueue(),
    pollInterval: Duration = .milliseconds(400)
  ) {
    self.queue = queue
    self.pollInterval = pollInterval
  }

  public func start(
    handler: @escaping @MainActor @Sendable (QueuedMeasurementRecord) async throws -> Void
  ) async {
    guard task == nil else { return }

    task = Task { [queue, pollInterval] in
      while !Task.isCancelled {
        await self.processPendingRecords(queue: queue, handler: handler)
        try? await Task.sleep(for: pollInterval)
      }
    }
  }

  public func stop() async {
    task?.cancel()
    task = nil
    activeRecordIds.removeAll()
  }

  private func processPendingRecords(
    queue: MeasurementRecordQueue,
    handler: @escaping @MainActor @Sendable (QueuedMeasurementRecord) async throws -> Void
  ) async {
    let queuedRecords: [QueuedMeasurementRecord]
    do {
      queuedRecords = try queue.pendingRecords()
    } catch {
      AppLogger.session.error("Failed to read AgentHub measurement records: \(error.localizedDescription)")
      return
    }

    for queued in queuedRecords {
      guard activeRecordIds.insert(queued.record.id).inserted else { continue }
      defer { activeRecordIds.remove(queued.record.id) }

      do {
        try await handler(queued)
        try queue.remove(queued)
      } catch {
        if shouldRetry(error, record: queued.record) {
          continue
        }
        AppLogger.session.error("Failed to handle AgentHub measurement record: \(error.localizedDescription)")
        do {
          try queue.markFailed(queued)
        } catch {
          AppLogger.session.error("Failed to mark AgentHub measurement record failed: \(error.localizedDescription)")
        }
      }
    }
  }

  /// A session that is not bound yet is a timing problem, not a bad record —
  /// keep retrying briefly before giving up on it.
  private func shouldRetry(_ error: Error, record: MeasurementRecord) -> Bool {
    guard let handlingError = error as? MeasurementRecordHandlingError,
          case .sessionUnavailable = handlingError
    else {
      return false
    }
    return Date.now.timeIntervalSince(record.createdAt) < 30
  }
}
