import Foundation
import Testing

@testable import AgentHubCLIKit

struct TaskTimeoutTests {
  @Test("Returns the operation's value when it finishes before the deadline")
  func returnsValueWhenFast() async throws {
    let value = try await withTimeout(.seconds(5)) {
      try await Task.sleep(for: .milliseconds(10))
      return 42
    }
    #expect(value == 42)
  }

  @Test("Throws TaskTimeoutError when the operation outlives the deadline")
  func throwsOnTimeout() async {
    await #expect(throws: TaskTimeoutError.self) {
      try await withTimeout(.milliseconds(20)) {
        try await Task.sleep(for: .seconds(10))
        return 0
      }
    }
  }

  @Test("Propagates the operation's own error instead of masking it as a timeout")
  func propagatesOperationError() async {
    struct Boom: Error, Equatable {}
    await #expect(throws: Boom.self) {
      try await withTimeout(.seconds(5)) {
        throw Boom()
      }
    }
  }

  @Test("Cancels the operation when the deadline wins")
  func cancelsOperationOnTimeout() async throws {
    let observedCancellation = ObservedFlag()
    await #expect(throws: TaskTimeoutError.self) {
      try await withTimeout(.milliseconds(20)) {
        do {
          try await Task.sleep(for: .seconds(10))
        } catch {
          // Task.sleep throws CancellationError when the task is cancelled.
          await observedCancellation.set()
          throw error
        }
      }
    }
    // Give the cancelled child a moment to run its catch block after the group
    // requests cancellation on timeout.
    try await Task.sleep(for: .milliseconds(100))
    #expect(await observedCancellation.value == true)
  }
}

private actor ObservedFlag {
  private(set) var value = false
  func set() { value = true }
}
