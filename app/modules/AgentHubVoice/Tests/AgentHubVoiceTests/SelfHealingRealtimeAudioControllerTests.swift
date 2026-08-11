import AVFoundation
import SwiftOpenAI
import Testing
@testable import AgentHubVoice

@RealtimeActor
private final class ScriptedAudioController: SwiftOpenAIAudioControlling {
  private(set) var microphoneStartCount = 0
  private(set) var stopCount = 0
  var playbackActive = false
  private var micContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  func microphoneStream() throws -> AsyncStream<AVAudioPCMBuffer> {
    microphoneStartCount += 1
    return AsyncStream { continuation in
      self.micContinuation = continuation
    }
  }

  func vend(_ buffer: AVAudioPCMBuffer) {
    micContinuation?.yield(buffer)
  }

  func playPCM16Audio(base64String _: String, itemID _: String?) {}

  func interruptPlayback() async -> Int? {
    nil
  }

  func playbackIsActive() -> Bool {
    playbackActive
  }

  func stop() {
    stopCount += 1
    micContinuation?.finish()
    micContinuation = nil
  }
}

@RealtimeActor
private final class RebuildFactorySpy {
  private let replacements: [ScriptedAudioController]
  private(set) var rebuildCount = 0

  init(replacements: [ScriptedAudioController]) {
    self.replacements = replacements
  }

  func make() throws -> any SwiftOpenAIAudioControlling {
    let controller = replacements[rebuildCount]
    rebuildCount += 1
    return controller
  }
}

private func makeBuffer(sample: Int16) -> AVAudioPCMBuffer {
  let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24000,
    channels: 1,
    interleaved: false
  )!
  let frames: AVAudioFrameCount = 240
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
  buffer.frameLength = frames
  if let data = buffer.int16ChannelData {
    for frame in 0..<Int(frames) {
      data[0][frame] = sample
    }
  }
  return buffer
}

/// Polls until `condition` holds, failing the test after a generous deadline.
private func waitUntil(
  _ comment: Comment,
  condition: @RealtimeActor () -> Bool
) async {
  for _ in 0..<400 {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
  let satisfied = await condition()
  #expect(satisfied, comment)
}

@RealtimeActor
struct SelfHealingRealtimeAudioControllerTests {
  @Test
  func rebuildsOnceWhenCaptureStaysDigitallySilent() async throws {
    let deadController = ScriptedAudioController()
    let healthyController = ScriptedAudioController()
    let factory = RebuildFactorySpy(replacements: [healthyController])
    let controller = SelfHealingRealtimeAudioController(
      initialController: deadController,
      rebuildController: { try factory.make() },
      liveAudioDeadline: .milliseconds(20)
    )

    let stream = try controller.microphoneStream()
    let received = ReceivedBuffers()
    let consumer = Task { @RealtimeActor in
      for await buffer in stream {
        await received.append(buffer)
      }
    }

    deadController.vend(makeBuffer(sample: 0))
    await waitUntil("the dead controller should be replaced") {
      factory.rebuildCount == 1
    }
    #expect(deadController.stopCount == 1)
    #expect(healthyController.microphoneStartCount == 1)

    healthyController.vend(makeBuffer(sample: 100))
    await waitUntilAsync("live buffer reaches the consumer via the same outer stream") {
      await received.containsLiveBuffer()
    }

    // A second silent window must not trigger another rebuild.
    try? await Task.sleep(for: .milliseconds(60))
    #expect(factory.rebuildCount == 1)

    controller.stop()
    consumer.cancel()
  }

  @Test
  func keepsControllerWhenLiveAudioArrives() async throws {
    let liveController = ScriptedAudioController()
    let factory = RebuildFactorySpy(replacements: [])
    let controller = SelfHealingRealtimeAudioController(
      initialController: liveController,
      rebuildController: { try factory.make() },
      liveAudioDeadline: .milliseconds(20)
    )

    let stream = try controller.microphoneStream()
    let consumer = Task { @RealtimeActor in
      for await _ in stream {}
    }

    liveController.vend(makeBuffer(sample: 42))
    try? await Task.sleep(for: .milliseconds(80))
    #expect(factory.rebuildCount == 0)
    #expect(liveController.stopCount == 0)

    controller.stop()
    consumer.cancel()
  }

  @Test
  func defersRebuildWhilePlaybackIsAudible() async throws {
    let deadController = ScriptedAudioController()
    deadController.playbackActive = true
    let healthyController = ScriptedAudioController()
    let factory = RebuildFactorySpy(replacements: [healthyController])
    let controller = SelfHealingRealtimeAudioController(
      initialController: deadController,
      rebuildController: { try factory.make() },
      liveAudioDeadline: .milliseconds(20)
    )

    let stream = try controller.microphoneStream()
    let consumer = Task { @RealtimeActor in
      for await _ in stream {}
    }

    try? await Task.sleep(for: .milliseconds(60))
    #expect(factory.rebuildCount == 0)

    deadController.playbackActive = false
    await waitUntil("rebuild should run once playback goes quiet") {
      factory.rebuildCount == 1
    }

    controller.stop()
    consumer.cancel()
  }

  @Test
  func stopPreventsPendingRebuild() async throws {
    let deadController = ScriptedAudioController()
    let factory = RebuildFactorySpy(replacements: [])
    let controller = SelfHealingRealtimeAudioController(
      initialController: deadController,
      rebuildController: { try factory.make() },
      liveAudioDeadline: .milliseconds(20)
    )

    _ = try controller.microphoneStream()
    controller.stop()

    try? await Task.sleep(for: .milliseconds(60))
    #expect(factory.rebuildCount == 0)
    #expect(deadController.stopCount == 1)
  }
}

private actor ReceivedBuffers {
  private var buffers = [AVAudioPCMBuffer]()

  func append(_ buffer: AVAudioPCMBuffer) {
    buffers.append(buffer)
  }

  func containsLiveBuffer() -> Bool {
    buffers.contains { buffer in
      guard let data = buffer.int16ChannelData else { return false }
      return (0..<Int(buffer.frameLength)).contains { data[0][$0] != 0 }
    }
  }
}

/// Polls an async condition until it holds, failing the test after a deadline.
private func waitUntilAsync(
  _ comment: Comment,
  condition: () async -> Bool
) async {
  for _ in 0..<400 {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
  let satisfied = await condition()
  #expect(satisfied, comment)
}
