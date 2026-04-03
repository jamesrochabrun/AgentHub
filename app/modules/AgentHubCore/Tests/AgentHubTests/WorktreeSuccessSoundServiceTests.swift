import Foundation
import Testing

@testable import AgentHubCore

@Suite("WorktreeSuccessSoundService")
struct WorktreeSuccessSoundServiceTests {

  @Test("Plays sound when called")
  func playsSound() async {
    let recorder = CallRecorder()
    let service = WorktreeSuccessSoundService(
      soundPlayer: {
        recorder.record()
      }
    )

    await service.playWorktreeCreatedSound()

    #expect(recorder.snapshot() == 1)
  }

  @Test("Plays sound multiple times")
  func playsMultipleTimes() async {
    let recorder = CallRecorder()
    let service = WorktreeSuccessSoundService(
      soundPlayer: {
        recorder.record()
      }
    )

    await service.playWorktreeCreatedSound()
    await service.playWorktreeCreatedSound()

    #expect(recorder.snapshot() == 2)
  }
}

private final class CallRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0

  func record() {
    lock.lock()
    callCount += 1
    lock.unlock()
  }

  func snapshot() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }
}
