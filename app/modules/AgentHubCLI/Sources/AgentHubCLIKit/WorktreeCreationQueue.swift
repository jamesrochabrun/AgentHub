import Foundation

actor WorktreeCreationQueue {
  private struct Waiter {
    let id: UUID
    let repoKey: String
    let continuation: CheckedContinuation<Void, Error>
  }

  private let maxConcurrentGlobally: Int
  private let maxConcurrentPerRepository: Int
  private var runningGlobal = 0
  private var runningByRepository: [String: Int] = [:]
  private var waiters: [Waiter] = []

  init(maxConcurrentGlobally: Int, maxConcurrentPerRepository: Int) {
    self.maxConcurrentGlobally = max(1, maxConcurrentGlobally)
    self.maxConcurrentPerRepository = max(1, maxConcurrentPerRepository)
  }

  func withPermit<T: Sendable>(
    repoKey: String,
    onQueued: (@Sendable () async -> Void)? = nil,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await waitForPermit(repoKey: repoKey, onQueued: onQueued)
    defer { release(repoKey: repoKey) }

    try Task.checkCancellation()
    return try await operation()
  }

  private func waitForPermit(
    repoKey: String,
    onQueued: (@Sendable () async -> Void)?
  ) async throws {
    try Task.checkCancellation()
    if canStart(repoKey: repoKey) {
      markStarted(repoKey: repoKey)
      return
    }

    if let onQueued {
      await onQueued()
    }

    try Task.checkCancellation()
    if canStart(repoKey: repoKey) {
      markStarted(repoKey: repoKey)
      return
    }

    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if canStart(repoKey: repoKey) {
          markStarted(repoKey: repoKey)
          continuation.resume()
          return
        }

        waiters.append(Waiter(
          id: waiterID,
          repoKey: repoKey,
          continuation: continuation
        ))
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(id: waiterID)
      }
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func release(repoKey: String) {
    runningGlobal = max(0, runningGlobal - 1)
    let repoRunning = max(0, (runningByRepository[repoKey] ?? 0) - 1)
    if repoRunning == 0 {
      runningByRepository[repoKey] = nil
    } else {
      runningByRepository[repoKey] = repoRunning
    }

    scheduleWaiters()
  }

  private func scheduleWaiters() {
    while let index = waiters.firstIndex(where: { canStart(repoKey: $0.repoKey) }) {
      let waiter = waiters.remove(at: index)
      markStarted(repoKey: waiter.repoKey)
      waiter.continuation.resume()
    }
  }

  private func canStart(repoKey: String) -> Bool {
    runningGlobal < maxConcurrentGlobally
      && (runningByRepository[repoKey] ?? 0) < maxConcurrentPerRepository
  }

  private func markStarted(repoKey: String) {
    runningGlobal += 1
    runningByRepository[repoKey, default: 0] += 1
  }
}
