import AVFoundation
import SwiftOpenAI
import Testing
@testable import AgentHubVoice

private struct RequestedAudioModes: Equatable {
  let records: Bool
  let playsBack: Bool

  init(_ modes: [AudioController.Mode]) {
    var records = false
    var playsBack = false

    for mode in modes {
      switch mode {
      case .record:
        records = true
      case .playback:
        playsBack = true
      }
    }

    self.records = records
    self.playsBack = playsBack
  }
}

@RealtimeActor
private final class FakeSwiftOpenAIAudioController: SwiftOpenAIAudioControlling {
  private(set) var microphoneStartCount = 0
  private(set) var playedAudio = [String]()
  private(set) var interruptionCount = 0
  private(set) var stopCount = 0

  func microphoneStream() throws -> AsyncStream<AVAudioPCMBuffer> {
    microphoneStartCount += 1
    return AsyncStream { continuation in
      continuation.finish()
    }
  }

  func playPCM16Audio(base64String: String, itemID _: String?) {
    playedAudio.append(base64String)
  }

  func interruptPlayback() async -> Int? {
    interruptionCount += 1
    return nil
  }

  func playbackIsActive() -> Bool {
    false
  }

  func stop() {
    stopCount += 1
  }
}

private struct AudioControllerFactoryError: Error {}

@RealtimeActor
private final class SwiftOpenAIAudioControllerFactorySpy {
  private let controllers: [FakeSwiftOpenAIAudioController]
  private let failingRequestIndex: Int?
  private var requestIndex = 0
  private(set) var requestedModes = [RequestedAudioModes]()

  init(
    controllers: [FakeSwiftOpenAIAudioController],
    failingRequestIndex: Int? = nil
  ) {
    self.controllers = controllers
    self.failingRequestIndex = failingRequestIndex
  }

  func make(
    modes: [AudioController.Mode]
  ) throws -> any SwiftOpenAIAudioControlling {
    let currentIndex = requestIndex
    requestIndex += 1
    requestedModes.append(RequestedAudioModes(modes))

    if currentIndex == failingRequestIndex {
      throw AudioControllerFactoryError()
    }

    return controllers[currentIndex]
  }
}

@RealtimeActor
struct RealtimeAudioControllerFactoryTests {
  @Test
  func sharesFullDuplexControllerForEchoCancellation() async throws {
    let sharedController = FakeSwiftOpenAIAudioController()
    let factory = SwiftOpenAIAudioControllerFactorySpy(
      controllers: [sharedController]
    )

    let controller = try await RealtimeAudioControllerFactory.make { modes in
      try factory.make(modes: modes)
    }

    _ = try controller.microphoneStream()
    controller.play(base64Audio: "audio", itemID: "item-1")
    _ = await controller.interruptPlayback()
    controller.stop()

    #expect(
      factory.requestedModes == [
        RequestedAudioModes([.record, .playback]),
      ]
    )
    #expect(sharedController.microphoneStartCount == 1)
    #expect(sharedController.playedAudio == ["audio"])
    #expect(sharedController.interruptionCount == 1)
    #expect(sharedController.stopCount == 1)
  }

  @Test
  func propagatesSharedControllerCreationFailure() async {
    let factory = SwiftOpenAIAudioControllerFactorySpy(
      controllers: [],
      failingRequestIndex: 0
    )

    await #expect(throws: AudioControllerFactoryError.self) {
      _ = try await RealtimeAudioControllerFactory.make { modes in
        try factory.make(modes: modes)
      }
    }
  }
}
