import Foundation
import Observation

@MainActor
public protocol SessionStatusObserving: AnyObject {
  func statusStream() -> AsyncStream<SessionStatus>
}

@MainActor
public final class SessionStatusObserver: SessionStatusObserving {
  private let status: @MainActor () -> SessionStatus?

  public init(status: @escaping @MainActor () -> SessionStatus?) {
    self.status = status
  }

  public convenience init(
    viewModel: CLISessionsViewModel,
    sessionId: String
  ) {
    self.init { [weak viewModel] in
      viewModel?.sessionStatuses[sessionId]
    }
  }

  public func statusStream() -> AsyncStream<SessionStatus> {
    AsyncStream { continuation in
      let observation = ObservationLifetime(owner: self)
      continuation.onTermination = { _ in
        Task { @MainActor in
          observation.cancel()
        }
      }
      track(continuation: continuation, lifetime: observation)
    }
  }

  private func track(
    continuation: AsyncStream<SessionStatus>.Continuation,
    lifetime: ObservationLifetime
  ) {
    guard !lifetime.isCancelled else { return }
    let current = withObservationTracking {
      status()
    } onChange: { [weak self, weak lifetime] in
      Task { @MainActor in
        guard let self, let lifetime, !lifetime.isCancelled else { return }
        self.track(
          continuation: continuation,
          lifetime: lifetime
        )
      }
    }
    if let current, current != lifetime.lastStatus {
      lifetime.lastStatus = current
      continuation.yield(current)
    }
  }
}

@MainActor
private final class ObservationLifetime {
  private(set) var isCancelled = false
  var lastStatus: SessionStatus?
  private var owner: SessionStatusObserver?

  init(owner: SessionStatusObserver) {
    self.owner = owner
  }

  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    owner = nil
  }
}
