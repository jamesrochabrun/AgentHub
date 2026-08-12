import AVFoundation
import SwiftOpenAI
import Testing
@testable import AgentHubVoice

@RealtimeActor
private final class FakeRealtimeTransport: RealtimeTransport {
  nonisolated let events: AsyncStream<OpenAIRealtimeMessage>
  private nonisolated let continuation:
    AsyncStream<OpenAIRealtimeMessage>.Continuation
  private(set) var commands: [RealtimeTransportCommand] = []
  private(set) var disconnected = false

  init() {
    (events, continuation) = AsyncStream.makeStream()
  }

  func send(_ command: RealtimeTransportCommand) async {
    commands.append(command)
  }

  func disconnect() {
    disconnected = true
    continuation.finish()
  }

  nonisolated func yield(_ event: OpenAIRealtimeMessage) {
    continuation.yield(event)
  }

  func sentCommands() -> [RealtimeTransportCommand] {
    commands
  }

  func isDisconnected() -> Bool {
    disconnected
  }
}

@RealtimeActor
private final class FakeRealtimeAudioController: RealtimeAudioControlling {
  private(set) var interruptionCount = 0
  private(set) var playedAudio: [String] = []
  private(set) var playedItemIDs: [String?] = []
  private let interruptionDurationMS: Int?
  var playbackActive = false
  private var micContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  init(interruptionDurationMS: Int? = nil) {
    self.interruptionDurationMS = interruptionDurationMS
  }

  func microphoneStream() throws -> AsyncStream<AVAudioPCMBuffer> {
    let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    micContinuation = continuation
    return stream
  }

  func yieldMicrophoneBuffer() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 24_000,
      channels: 1,
      interleaved: true
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
    buffer.frameLength = 240
    micContinuation?.yield(buffer)
  }

  func setPlaybackActive(_ active: Bool) {
    playbackActive = active
  }

  func play(base64Audio: String, itemID: String?) {
    playedAudio.append(base64Audio)
    playedItemIDs.append(itemID)
  }

  func interruptPlayback() async -> Int? {
    interruptionCount += 1
    return interruptionDurationMS
  }

  func isPlaybackActive() -> Bool {
    playbackActive
  }

  func stop() {}

  func interruptions() -> Int {
    interruptionCount
  }
}

@MainActor
struct RealtimeVoiceEngineTests {
  @Test
  func transitionsToReadyAndDispatchesFunctionOutputBeforeResponse() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)
    let registry = VoiceToolRegistry(
      tools: [
        VoiceTool(
          name: "list_sessions",
          description: "List sessions",
          parameters: ["type": "object"]
        ) { _ in
          #"{"status":"ok"}"#
        }
      ]
    )

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(),
      tools: registry
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }
    transport.yield(
      .responseFunctionCallArgumentsDone(
        name: "list_sessions",
        arguments: "{}",
        callID: "call-1",
        itemID: nil,
        responseID: nil
      )
    )
    await waitUntil {
      await transport.sentCommands().count == 2
    }

    #expect(
      await transport.sentCommands() == [
        .functionOutput(callID: "call-1", output: #"{"status":"ok"}"#),
        .responseCreate,
      ]
    )
    #expect(engine.state == .thinking)
    #expect(!engine.isMicrophoneMuted)
  }

  @Test
  func backgroundUpdateWaitsForActiveResponseToFinish() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)
    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    transport.yield(.responseCreated(responseID: "response-1"))
    await waitUntil { engine.state == .thinking }

    engine.pushBackgroundUpdate("Session finished")
    await Task.yield()
    #expect(await transport.sentCommands().isEmpty)

    transport.yield(
      .responseDone(responseID: "response-1", status: "completed", statusDetails: nil)
    )
    await waitUntil {
      await transport.sentCommands().count == 2
    }
    #expect(
      await transport.sentCommands() == [
        .backgroundUpdate("Session finished"),
        .responseCreate,
      ]
    )
  }

  @Test
  func completedToolResponseDoesNotIdleWhileContinuationIsPending() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)
    let registry = VoiceToolRegistry(
      tools: [
        VoiceTool(
          name: "list_sessions",
          description: "List sessions",
          parameters: ["type": "object"]
        ) { _ in
          #"{"status":"ok"}"#
        }
      ]
    )
    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(),
      tools: registry
    )
    transport.yield(.sessionUpdated)
    transport.yield(.responseCreated(responseID: "tool-response"))
    transport.yield(
      .responseFunctionCallArgumentsDone(
        name: "list_sessions",
        arguments: "{}",
        callID: "call-1",
        itemID: nil,
        responseID: "tool-response"
      )
    )
    await waitUntil {
      await transport.sentCommands().count == 2
    }

    engine.pushBackgroundUpdate("Session finished")
    transport.yield(
      .responseDone(
        responseID: "tool-response",
        status: "completed",
        statusDetails: nil
      )
    )
    await Task.yield()

    #expect(engine.state == .thinking)
    #expect(await transport.sentCommands().count == 2)

    transport.yield(.responseCreated(responseID: "continuation-response"))
    transport.yield(
      .responseDone(
        responseID: "continuation-response",
        status: "completed",
        statusDetails: nil
      )
    )
    await waitUntil {
      await transport.sentCommands().count == 4
    }
    #expect(
      await transport.sentCommands().suffix(2) == [
        .backgroundUpdate("Session finished"),
        .responseCreate,
      ]
    )
  }

  @Test
  func backgroundQueueDropsOldestUpdateAfterFiveItems() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)
    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    transport.yield(.responseCreated(responseID: "response-1"))
    await waitUntil { engine.state == .thinking }

    for index in 1...6 {
      engine.pushBackgroundUpdate("Update \(index)")
    }
    transport.yield(
      .responseDone(
        responseID: "response-1",
        status: "completed",
        statusDetails: nil
      )
    )
    await waitUntil {
      await transport.sentCommands().count == 2
    }

    #expect(
      await transport.sentCommands().first == .backgroundUpdate("Update 2")
    )
  }

  @Test
  func speechStartInterruptsPlaybackAndFatalErrorsDisconnect() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController(interruptionDurationMS: 750)
    let engine = makeEngine(transport: transport, audio: audio)
    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    transport.yield(
      .responseAudioDelta(
        itemID: "assistant-item-1",
        responseID: "response-1",
        delta: "audio"
      )
    )
    transport.yield(
      .inputAudioBufferSpeechStarted(itemID: nil, audioStartMS: nil)
    )
    await waitUntil { engine.state == .userSpeaking }
    #expect(await audio.interruptions() == 1)
    #expect(
      await transport.sentCommands() == [
        .truncateAudio(itemID: "assistant-item-1", audioEndMS: 750)
      ]
    )

    transport.yield(.error("invalid_api_key"))
    await waitUntil {
      if case .failed = engine.state { return true }
      return false
    }

    #expect(await transport.isDisconnected())
  }

  @Test
  func turnDetectedCancellationDoesNotSurfaceAsAnError() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    transport.yield(.responseCreated(responseID: "response-1"))
    await waitUntil { engine.state == .thinking }

    transport.yield(
      .responseDone(
        responseID: "response-1",
        status: "cancelled",
        statusDetails: [
          "status_details": [
            "type": "cancelled",
            "reason": "turn_detected",
          ]
        ]
      )
    )
    await waitUntil { engine.state == .idle }

    #expect(engine.errorMessage == nil)
    #expect(!(await transport.isDisconnected()))
  }

  @Test
  func failedResponseShowsConciseErrorAndDisconnectsWhenFatal() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    transport.yield(.responseCreated(responseID: "response-1"))
    await waitUntil { engine.state == .thinking }

    transport.yield(
      .responseDone(
        responseID: "response-1",
        status: "failed",
        statusDetails: [
          "status_details": [
            "type": "failed",
            "error": [
              "code": "invalid_api_key",
              "message": "The API key is invalid.",
            ],
          ]
        ]
      )
    )
    await waitUntil {
      if case .failed = engine.state { return true }
      return false
    }

    #expect(engine.errorMessage == "invalid_api_key: The API key is invalid.")
    #expect(await transport.isDisconnected())
  }

  @Test
  func playbackGatesMicrophoneUntilBargeInIsAllowed() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(allowBargeIn: false),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }

    await audio.setPlaybackActive(true)
    await audio.yieldMicrophoneBuffer()
    for _ in 0..<20 {
      await Task.yield()
    }
    let sentWhileGated = await transport.sentCommands().contains {
      if case .inputAudio = $0 { return true }
      return false
    }
    #expect(!sentWhileGated)

    await audio.setPlaybackActive(false)
    await audio.yieldMicrophoneBuffer()
    await waitUntil {
      await transport.sentCommands().contains {
        if case .inputAudio = $0 { return true }
        return false
      }
    }
    let sentAfterPlayback = await transport.sentCommands().contains {
      if case .inputAudio = $0 { return true }
      return false
    }
    #expect(sentAfterPlayback)
  }

  @Test
  func backgroundUpdateDeliveryGatesMicrophoneUntilTurnSettles() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(allowBargeIn: false),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }

    engine.pushBackgroundUpdate("Session finished")
    await waitUntil {
      await transport.sentCommands().count == 2
    }

    // Between the flush and the announcement finishing, background noise
    // must not reach the server as a phantom user turn.
    await audio.yieldMicrophoneBuffer()
    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(!(await sentInputAudio(transport)))
    #expect(engine.microphoneLevel == 0)
    // The gate is transient plumbing — it must not read as a user mute,
    // but the UI must still be able to show the mic as paused.
    #expect(!engine.isMicrophoneMuted)
    #expect(engine.isMicrophoneGated)

    transport.yield(.responseCreated(responseID: "announce-1"))
    transport.yield(
      .responseDone(
        responseID: "announce-1",
        status: "completed",
        statusDetails: nil
      )
    )
    await waitUntil { engine.state == .idle }
    #expect(!engine.isMicrophoneGated)

    await audio.yieldMicrophoneBuffer()
    await waitUntil { await sentInputAudio(transport) }
    #expect(await sentInputAudio(transport))
  }

  @Test
  func bargeInKeepsMicrophoneLiveDuringBackgroundUpdateDelivery() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(allowBargeIn: true),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }

    engine.pushBackgroundUpdate("Session finished")
    await waitUntil {
      await transport.sentCommands().count == 2
    }

    await audio.yieldMicrophoneBuffer()
    await waitUntil { await sentInputAudio(transport) }
    #expect(await sentInputAudio(transport))
    #expect(!engine.isMicrophoneGated)
  }

  @Test
  func failedAnnouncementReleasesTheDeliveryGate() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(allowBargeIn: false),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }

    engine.pushBackgroundUpdate("Session finished")
    await waitUntil {
      await transport.sentCommands().count == 2
    }

    transport.yield(.responseCreated(responseID: "announce-1"))
    transport.yield(
      .responseDone(
        responseID: "announce-1",
        status: "failed",
        statusDetails: [
          "status_details": [
            "type": "failed",
            "error": [
              "code": "server_error",
              "message": "The server had a hiccup.",
            ],
          ]
        ]
      )
    )
    await waitUntil { engine.state == .idle }

    await audio.yieldMicrophoneBuffer()
    await waitUntil { await sentInputAudio(transport) }
    #expect(await sentInputAudio(transport))
  }

  @Test
  func standbyMutesMicrophoneWhileAwaitingBackgroundWork() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(allowBargeIn: false),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }

    engine.setAwaitingBackgroundWork(true)
    #expect(engine.isStandbyMuted)
    #expect(!engine.isMicrophoneMuted)

    await audio.yieldMicrophoneBuffer()
    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(!(await sentInputAudio(transport)))

    engine.setAwaitingBackgroundWork(false)
    #expect(!engine.isStandbyMuted)
    await audio.yieldMicrophoneBuffer()
    await waitUntil { await sentInputAudio(transport) }
    #expect(await sentInputAudio(transport))
  }

  @Test
  func standbyOverrideStaysReleasedUntilTheNextWaitBegins() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(allowBargeIn: false),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }

    engine.setAwaitingBackgroundWork(true)
    #expect(engine.isStandbyMuted)

    // The user taps unmute to talk mid-wait: standby releases and repeated
    // "still waiting" signals must not re-mute them.
    engine.overrideStandbyMute()
    #expect(!engine.isStandbyMuted)
    engine.setAwaitingBackgroundWork(true)
    #expect(!engine.isStandbyMuted)

    // A fresh wait after this one ends re-engages standby.
    engine.setAwaitingBackgroundWork(false)
    engine.setAwaitingBackgroundWork(true)
    #expect(engine.isStandbyMuted)
  }

  @Test
  func standbyNeverClobbersTheUserMute() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(allowBargeIn: false),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }

    engine.setMicrophoneMuted(true)
    engine.setAwaitingBackgroundWork(true)
    #expect(!engine.isStandbyMuted)
    #expect(engine.isMicrophoneMuted)

    // The wait ending must not unmute a user who muted themselves.
    engine.setAwaitingBackgroundWork(false)
    #expect(engine.isMicrophoneMuted)
  }

  @Test
  func assistantSpeakingFollowsAudiblePlaybackNotDeltaArrival() async {
    let transport = await FakeRealtimeTransport()
    let audio = await FakeRealtimeAudioController()
    let engine = makeEngine(transport: transport, audio: audio)

    await engine.start(
      service: OpenAIServiceFactory.service(apiKey: "test"),
      settings: VoiceEngineSettings(),
      tools: VoiceToolRegistry(tools: [])
    )
    transport.yield(.sessionUpdated)
    await waitUntil { engine.state == .idle }

    // A delta starts speaking immediately, without waiting for a mic tick.
    await audio.setPlaybackActive(true)
    transport.yield(
      .responseAudioDelta(itemID: "item-1", responseID: "resp-1", delta: "")
    )
    await waitUntil { engine.isAssistantSpeaking }
    #expect(engine.isAssistantSpeaking)

    // Deltas stop arriving (network done) while audio is still audibly
    // playing — the orb must keep animating through the whole response.
    transport.yield(.responseAudioDone(itemID: "item-1", responseID: "resp-1"))
    await audio.yieldMicrophoneBuffer()
    await waitUntil { engine.assistantLevel == 0 }
    #expect(engine.isAssistantSpeaking)

    // The playback queue drains; the next mic tick flips speaking off.
    await audio.setPlaybackActive(false)
    await audio.yieldMicrophoneBuffer()
    await waitUntil { !engine.isAssistantSpeaking }
    #expect(!engine.isAssistantSpeaking)
  }

  private func sentInputAudio(_ transport: FakeRealtimeTransport) async -> Bool {
    await transport.sentCommands().contains {
      if case .inputAudio = $0 { return true }
      return false
    }
  }

  private func makeEngine(
    transport: FakeRealtimeTransport,
    audio: FakeRealtimeAudioController
  ) -> RealtimeVoiceEngine {
    RealtimeVoiceEngine(
      transportFactory: { _, _, _ in transport },
      audioFactory: { audio },
      permissionRequester: { true }
    )
  }

  private func waitUntil(
    _ predicate: @escaping @MainActor () async -> Bool
  ) async {
    for _ in 0..<200 {
      if await predicate() {
        return
      }
      await Task.yield()
    }
  }
}
