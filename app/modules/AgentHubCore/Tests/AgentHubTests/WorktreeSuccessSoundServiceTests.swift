import Foundation
import Testing

@testable import AgentHubCore

@Suite("WorktreeSuccessSoundService")
struct WorktreeSuccessSoundServiceTests {

  @Test("Missing bundled sound falls back to the system alert")
  func missingResourceFallsBack() async {
    let fallbackRecorder = FallbackRecorder()
    let service = WorktreeSuccessSoundService(
      playerFactory: { _ in MockAudioPlayer(shouldPlay: true) },
      resourceLocator: { nil },
      fallbackPlayer: {
        fallbackRecorder.record()
      }
    )

    await service.playWorktreeCreatedSound()

    #expect(fallbackRecorder.snapshot() == 1)
  }

  @Test("Playable bundled sound does not fall back")
  func successfulPlaybackSkipsFallback() async {
    let fallbackRecorder = FallbackRecorder()
    let player = MockAudioPlayer(shouldPlay: true)
    let service = WorktreeSuccessSoundService(
      playerFactory: { _ in player },
      resourceLocator: { URL(fileURLWithPath: "/tmp/worktree-success.wav") },
      fallbackPlayer: {
        fallbackRecorder.record()
      }
    )

    await service.playWorktreeCreatedSound()

    #expect(fallbackRecorder.snapshot() == 0)
    #expect(player.prepareCallCount == 1)
    #expect(player.playCallCount == 1)
  }

  @Test("Failed playback falls back to the system alert")
  func failedPlaybackFallsBack() async {
    let fallbackRecorder = FallbackRecorder()
    let player = MockAudioPlayer(shouldPlay: false)
    let service = WorktreeSuccessSoundService(
      playerFactory: { _ in player },
      resourceLocator: { URL(fileURLWithPath: "/tmp/worktree-success.wav") },
      fallbackPlayer: {
        fallbackRecorder.record()
      }
    )

    await service.playWorktreeCreatedSound()

    #expect(fallbackRecorder.snapshot() == 1)
    #expect(player.playCallCount == 1)
  }
}

private final class FallbackRecorder: @unchecked Sendable {
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

private final class MockAudioPlayer: WorktreeSuccessAudioPlayer, @unchecked Sendable {
  let shouldPlay: Bool
  let duration: TimeInterval = 0.05

  private(set) var prepareCallCount = 0
  private(set) var playCallCount = 0

  init(shouldPlay: Bool) {
    self.shouldPlay = shouldPlay
  }

  func prepareToPlay() -> Bool {
    prepareCallCount += 1
    return true
  }

  func play() -> Bool {
    playCallCount += 1
    return shouldPlay
  }
}
