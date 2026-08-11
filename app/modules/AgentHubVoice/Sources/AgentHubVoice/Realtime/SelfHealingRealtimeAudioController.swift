@preconcurrency import AVFoundation
import OSLog
import SwiftOpenAI

private let logger = Logger(subsystem: "com.agenthub.voice", category: "Audio")

/// Wraps the shared record/playback controller and heals a dead capture graph.
///
/// On the first voice session after app launch, enabling voice processing can fail inside
/// CoreAudio (`AUVPAggregate: Timeout waiting for streams`, `-10877`): the engine reports it
/// started, but the input HAL stream never runs — macOS shows no microphone indicator and the
/// tap delivers only digital silence. A second attempt with a fresh engine reliably succeeds
/// because the voice-processing aggregate device already exists.
///
/// A healthy microphone always carries a noise floor, so exact-zero samples across the deadline
/// window mean capture is dead (or voice processing is gating true silence — rebuilding then is
/// harmless). When that happens this controller tears the inner controller down and rebuilds it
/// once, piping the fresh capture into the same outer stream so the session never notices.
@RealtimeActor
final class SelfHealingRealtimeAudioController: RealtimeAudioControlling {
  init(
    initialController: any SwiftOpenAIAudioControlling,
    rebuildController: @escaping @RealtimeActor @Sendable () async throws
      -> any SwiftOpenAIAudioControlling,
    liveAudioDeadline: Duration = .seconds(2)
  ) {
    controller = initialController
    self.rebuildController = rebuildController
    self.liveAudioDeadline = liveAudioDeadline
  }

  func microphoneStream() throws -> AsyncStream<AVAudioPCMBuffer> {
    let inner = try controller.microphoneStream()
    let stream = AsyncStream<AVAudioPCMBuffer> { [weak self] continuation in
      guard let this = self else {
        continuation.finish()
        return
      }
      this.continuation = continuation
    }
    pump(inner)
    scheduleWatchdog()
    return stream
  }

  func play(base64Audio: String, itemID: String?) {
    controller.playPCM16Audio(base64String: base64Audio, itemID: itemID)
  }

  func interruptPlayback() async -> Int? {
    await controller.interruptPlayback()
  }

  func isPlaybackActive() -> Bool {
    controller.playbackIsActive()
  }

  func stop() {
    isStopped = true
    watchdogTask?.cancel()
    watchdogTask = nil
    pumpTask?.cancel()
    pumpTask = nil
    continuation?.finish()
    continuation = nil
    controller.stop()
  }

  private var controller: any SwiftOpenAIAudioControlling
  private let rebuildController: @RealtimeActor @Sendable () async throws
    -> any SwiftOpenAIAudioControlling
  private let liveAudioDeadline: Duration
  private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  private var pumpTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var hasSeenLiveAudio = false
  private var hasRebuilt = false
  private var isStopped = false

  private func pump(_ inner: AsyncStream<AVAudioPCMBuffer>) {
    pumpTask?.cancel()
    pumpTask = Task { @RealtimeActor [weak self] in
      for await buffer in inner {
        guard let self, !Task.isCancelled else { return }
        if !hasSeenLiveAudio, Self.containsLiveAudio(buffer) {
          hasSeenLiveAudio = true
        }
        continuation?.yield(buffer)
      }
      guard let self, !Task.isCancelled else { return }
      continuation?.finish()
      continuation = nil
    }
  }

  private func scheduleWatchdog() {
    watchdogTask?.cancel()
    watchdogTask = Task { @RealtimeActor [weak self] in
      guard let deadline = self?.liveAudioDeadline else { return }
      try? await Task.sleep(for: deadline)
      guard !Task.isCancelled else { return }
      await self?.rebuildIfCaptureIsDead()
    }
  }

  private func rebuildIfCaptureIsDead() async {
    guard !isStopped, !hasRebuilt, !hasSeenLiveAudio else { return }
    // Rebuilding swaps the shared playback graph too — don't cut off audible
    // assistant audio; check again after another deadline window.
    guard !controller.playbackIsActive() else {
      scheduleWatchdog()
      return
    }
    hasRebuilt = true
    logger.warning(
      "Microphone capture produced no live audio; rebuilding the voice audio graph"
    )
    pumpTask?.cancel()
    pumpTask = nil
    // Audio teardown blocks on default-QoS CoreAudio work; keep it at utility
    // so it doesn't trip the priority-inversion diagnostic.
    let previous = controller
    await Task.detached(priority: .utility) {
      await previous.stop()
    }.value
    guard !isStopped else { return }
    do {
      let fresh = try await rebuildController()
      controller = fresh
      pump(try fresh.microphoneStream())
      logger.info("Voice audio graph rebuilt after dead capture")
    } catch {
      logger.error(
        "Voice audio graph rebuild failed: \(error.localizedDescription)"
      )
      continuation?.finish()
      continuation = nil
    }
  }

  private nonisolated static func containsLiveAudio(
    _ buffer: AVAudioPCMBuffer
  ) -> Bool {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return false }
    let channels = Int(buffer.format.channelCount)
    if let int16Data = buffer.int16ChannelData {
      for channel in 0..<channels {
        for frame in 0..<frames where int16Data[channel][frame] != 0 {
          return true
        }
      }
      return false
    }
    if let floatData = buffer.floatChannelData {
      for channel in 0..<channels {
        for frame in 0..<frames where floatData[channel][frame] != 0 {
          return true
        }
      }
      return false
    }
    return false
  }
}
