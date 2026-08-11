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
    controllerFactory: @escaping SwiftOpenAIAudioControllerFactory,
    liveAudioDeadline: Duration = .seconds(2)
  ) async throws -> any RealtimeAudioControlling {
    let controller = try await controllerFactory([.record, .playback])
    // The first voice-processing session after app launch can come up with a
    // dead capture stream (AUVPAggregate timeout); the wrapper rebuilds the
    // controller once when the microphone stays digitally silent.
    return SelfHealingRealtimeAudioController(
      initialController: controller,
      rebuildController: { try await controllerFactory([.record, .playback]) },
      liveAudioDeadline: liveAudioDeadline
    )
  }
}
