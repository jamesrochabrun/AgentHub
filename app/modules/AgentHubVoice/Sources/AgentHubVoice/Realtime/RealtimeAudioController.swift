@preconcurrency import AVFoundation
import SwiftOpenAI

@RealtimeActor
public protocol RealtimeAudioControlling: AnyObject, Sendable {
  func microphoneStream() throws -> AsyncStream<AVAudioPCMBuffer>
  func play(base64Audio: String, itemID: String?)
  func interruptPlayback() async -> Int?
  func isPlaybackActive() -> Bool
  func stop()
}

@RealtimeActor
protocol SwiftOpenAIAudioControlling: AnyObject, Sendable {
  func microphoneStream() throws -> AsyncStream<AVAudioPCMBuffer>
  func playPCM16Audio(base64String: String, itemID: String?)
  func interruptPlayback() async -> Int?
  func playbackIsActive() -> Bool
  func stop()
}

extension AudioController: SwiftOpenAIAudioControlling {
  func microphoneStream() throws -> AsyncStream<AVAudioPCMBuffer> {
    try micStream()
  }

  func playbackIsActive() -> Bool {
    isPlaybackActive
  }
}

@RealtimeActor
public final class LiveRealtimeAudioController: RealtimeAudioControlling {
  private let microphoneController: any SwiftOpenAIAudioControlling
  private let playbackController: any SwiftOpenAIAudioControlling

  public init(controller: AudioController) {
    microphoneController = controller
    playbackController = controller
  }

  init(
    sharedController: any SwiftOpenAIAudioControlling
  ) {
    microphoneController = sharedController
    playbackController = sharedController
  }

  public func microphoneStream() throws -> AsyncStream<AVAudioPCMBuffer> {
    try microphoneController.microphoneStream()
  }

  public func play(base64Audio: String, itemID: String?) {
    playbackController.playPCM16Audio(base64String: base64Audio, itemID: itemID)
  }

  public func interruptPlayback() async -> Int? {
    await playbackController.interruptPlayback()
  }

  public func isPlaybackActive() -> Bool {
    playbackController.playbackIsActive()
  }

  public func stop() {
    microphoneController.stop()
    if playbackController !== microphoneController {
      playbackController.stop()
    }
  }
}
