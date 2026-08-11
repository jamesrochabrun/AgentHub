import SwiftOpenAI

typealias SwiftOpenAIAudioControllerFactory =
  @RealtimeActor @Sendable (
    _ modes: [AudioController.Mode]
  ) async throws -> any SwiftOpenAIAudioControlling

@RealtimeActor
public enum RealtimeAudioControllerFactory {
  /// A shared record/playback controller gives the voice-processing graph the downlink reference
  /// it needs for acoustic echo cancellation while keeping microphone capture live for barge-in.
  public static func make() async throws -> any RealtimeAudioControlling {
    try await make { modes in
      try await AudioController(modes: modes)
    }
  }

  static func make(
    controllerFactory: @escaping SwiftOpenAIAudioControllerFactory
  ) async throws -> any RealtimeAudioControlling {
    let controller = try await controllerFactory([.record, .playback])
    return LiveRealtimeAudioController(sharedController: controller)
  }
}
