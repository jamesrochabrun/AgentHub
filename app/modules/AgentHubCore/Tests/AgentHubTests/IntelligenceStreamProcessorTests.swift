import Combine
import Foundation
import Testing

import ClaudeCodeClient
@testable import AgentHubCore

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@Suite("IntelligenceStreamProcessor")
struct IntelligenceStreamProcessorTests {

  @Test("Timeout cancels upstream subscription")
  @MainActor
  func timeoutCancelsSubscription() async {
    let processor = IntelligenceStreamProcessor(timeoutNanoseconds: 5_000_000)
    let cancelFlag = LockedFlag()
    let subject = PassthroughSubject<StreamJSONChunk, Error>()
    let publisher = subject
      .handleEvents(receiveCancel: { cancelFlag.set() })
      .eraseToAnyPublisher()
    var receivedError: Error?

    processor.onError = { receivedError = $0 }

    await processor.processStream(publisher)

    #expect(cancelFlag.get())

    guard let processError = receivedError as? ClaudeCodeClientError,
          case .timeout(let seconds) = processError else {
      Issue.record("Expected timeout error, got \(String(describing: receivedError))")
      return
    }

    #expect(seconds < 1)
  }
}
