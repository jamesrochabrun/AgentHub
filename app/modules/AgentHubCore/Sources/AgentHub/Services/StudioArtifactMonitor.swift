import AgentHubCLIKit
import Foundation

public protocol StudioArtifactMonitorProtocol: AnyObject, Sendable {
  func start(handler: @escaping @MainActor @Sendable (QueuedStudioArtifact) async throws -> Void) async
  func stop() async
}

/// Drains Studio artifacts the `agenthub` CLI queued on disk into the app.
///
/// Same shape as `MeasurementRecordMonitor`: poll the queue directory, hand each
/// artifact to the app, and only delete the file once the app has taken it. An
/// artifact whose session cannot be resolved yet is left in place and retried,
/// because the CLI can file one a moment before AgentHub has bound the session id.
public actor StudioArtifactMonitor: StudioArtifactMonitorProtocol {
  private let queue: StudioArtifactQueue
  private let pollInterval: Duration
  private var task: Task<Void, Never>?
  private var activeIds: Set<String> = []

  public init(
    queue: StudioArtifactQueue = StudioArtifactQueue(),
    pollInterval: Duration = .milliseconds(400)
  ) {
    self.queue = queue
    self.pollInterval = pollInterval
  }

  public func start(
    handler: @escaping @MainActor @Sendable (QueuedStudioArtifact) async throws -> Void
  ) async {
    guard task == nil else { return }

    task = Task { [queue, pollInterval] in
      while !Task.isCancelled {
        await self.processPending(queue: queue, handler: handler)
        try? await Task.sleep(for: pollInterval)
      }
    }
  }

  public func stop() async {
    task?.cancel()
    task = nil
    activeIds.removeAll()
  }

  private func processPending(
    queue: StudioArtifactQueue,
    handler: @escaping @MainActor @Sendable (QueuedStudioArtifact) async throws -> Void
  ) async {
    let pending: [QueuedStudioArtifact]
    do {
      pending = try queue.pendingArtifacts()
    } catch {
      AppLogger.session.error("Failed to read AgentHub studio records: \(error.localizedDescription)")
      return
    }

    for queued in pending {
      guard activeIds.insert(queued.artifact.id).inserted else { continue }
      defer { activeIds.remove(queued.artifact.id) }

      do {
        try await handler(queued)
        try queue.remove(queued)
      } catch {
        if shouldRetry(error, artifact: queued.artifact) {
          continue
        }
        AppLogger.session.error("Failed to handle AgentHub studio record: \(error.localizedDescription)")
        do {
          try queue.markFailed(queued)
        } catch {
          AppLogger.session.error("Failed to mark AgentHub studio record failed: \(error.localizedDescription)")
        }
      }
    }
  }

  /// A session that is not bound yet is a timing problem, not a bad record —
  /// keep retrying briefly before giving up on it.
  func shouldRetry(_ error: Error, artifact: StudioArtifact) -> Bool {
    guard let handlingError = error as? StudioArtifactHandlingError,
          case .sessionUnavailable = handlingError
    else {
      return false
    }
    return Date.now.timeIntervalSince(artifact.createdAt) < 30
  }
}
