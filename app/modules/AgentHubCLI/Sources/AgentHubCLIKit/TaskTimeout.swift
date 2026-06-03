import Foundation

/// Thrown by ``withTimeout(_:operation:)`` when `operation` does not finish
/// before the supplied `duration` elapses.
public struct TaskTimeoutError: Error, Equatable {
  public init() {}
}

/// Runs `operation`, racing it against `duration`.
///
/// Returns the operation's value if it finishes first. Otherwise the operation
/// task is cancelled and ``TaskTimeoutError`` is thrown. Cancellation is
/// cooperative: the operation must honor `Task` cancellation for the timeout to
/// free its resources promptly (an uncancellable busy-loop would still block the
/// task group's implicit await on scope exit). If `operation` throws its own
/// error before the deadline, that error is propagated unchanged.
public func withTimeout<T: Sendable>(
  _ duration: Duration,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw TaskTimeoutError()
    }

    defer { group.cancelAll() }
    guard let result = try await group.next() else {
      throw TaskTimeoutError()
    }
    return result
  }
}
