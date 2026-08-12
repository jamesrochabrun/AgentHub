import Foundation
import Observation
@preconcurrency import AVFoundation
import SwiftOpenAI

public typealias RealtimeTransportFactory =
  @RealtimeActor @Sendable (
    _ service: any OpenAIService,
    _ model: String,
    _ configuration: OpenAIRealtimeSessionConfiguration
  ) async throws -> any RealtimeTransport

public typealias RealtimeAudioFactory =
  @RealtimeActor @Sendable () async throws -> any RealtimeAudioControlling

private actor RealtimeReadyState {
  private var value = false

  func set(_ value: Bool) {
    self.value = value
  }

  func get() -> Bool {
    value
  }
}

@Observable
@MainActor
public final class RealtimeVoiceEngine {
  public private(set) var state: VoiceEngineState = .disconnected
  public private(set) var transcripts: [VoiceTranscriptEntry] = []
  public private(set) var microphoneLevel: Float = 0
  public private(set) var assistantLevel: Float = 0
  /// True while assistant audio is audibly playing. Unlike `assistantLevel`,
  /// which tracks network delta arrival (OpenAI streams audio much faster
  /// than realtime), this follows actual playback so UI stays animated for
  /// the full spoken response.
  public private(set) var isAssistantSpeaking = false
  public private(set) var errorMessage: String?
  public private(set) var isMicrophoneMuted = false
  /// True while the delivery gate is dropping microphone frames (a session
  /// announcement is in flight). The UI should render the microphone as
  /// paused — showing a hot mic here would misstate what the engine hears.
  public var isMicrophoneGated: Bool { isDeliveringBackgroundUpdate }
  /// True while the engine auto-muted the microphone because a session
  /// completion is being awaited: background noise during a long wait would
  /// otherwise reach the model as phantom turns. Unlike the delivery gate
  /// this is user-overridable — tapping unmute releases it for the current
  /// wait.
  public private(set) var isStandbyMuted = false

  private let transportFactory: RealtimeTransportFactory
  private let audioFactory: RealtimeAudioFactory
  private let permissionRequester: @Sendable () async -> Bool
  private var transport: (any RealtimeTransport)?
  private var audioController: (any RealtimeAudioControlling)?
  private var sessionTask: Task<Void, Never>?
  private var microphoneTask: Task<Void, Never>?
  private var reducer = VoiceTranscriptReducer()
  private var activeResponseID: String?
  private var currentAudioItemID: String?
  private var isResponseCreatePending = false
  private var backgroundUpdates: [String] = []
  private var allowBargeIn = false
  /// Gates the microphone while a background update is being delivered —
  /// from flush until the announcement's turn settles. In that window the
  /// engine is between responses, so background noise would either interrupt
  /// the pending announcement or be committed as a phantom user turn.
  /// Deliberately separate from `isMicrophoneMuted`, which is the user's
  /// manual mute and must never be clobbered by this transient gate.
  private var isDeliveringBackgroundUpdate = false
  private var isAwaitingBackgroundWork = false

  public init(
    transportFactory: @escaping RealtimeTransportFactory = {
      service,
      model,
      configuration in
      let session = try await service.realtimeSession(
        model: model,
        configuration: configuration
      )
      return LiveRealtimeTransport(session: session)
    },
    audioFactory: @escaping RealtimeAudioFactory = {
      try await RealtimeAudioControllerFactory.make()
    },
    permissionRequester: @escaping @Sendable () async -> Bool = {
      await MicrophoneAccess.request()
    }
  ) {
    self.transportFactory = transportFactory
    self.audioFactory = audioFactory
    self.permissionRequester = permissionRequester
  }

  public func start(
    service: any OpenAIService,
    settings: VoiceEngineSettings,
    tools: VoiceToolRegistry,
    sessionContext: String? = nil
  ) async {
    stop()
    state = .connecting
    errorMessage = nil

    guard await permissionRequester() else {
      fail("Microphone permission is required for conversation mode.")
      return
    }
    allowBargeIn = settings.allowBargeIn

    do {
      let configuration = RealtimeSessionConfigurationBuilder.make(
        settings: settings,
        tools: tools,
        sessionContext: sessionContext
      )
      let pair = try await Task { @RealtimeActor in
        let transport = try await transportFactory(
          service,
          settings.model,
          configuration
        )
        let audio = try await audioFactory()
        return (transport, audio)
      }.value
      transport = pair.0
      audioController = pair.1
      beginStreaming(
        transport: pair.0,
        audio: pair.1,
        tools: tools,
        allowBargeIn: settings.allowBargeIn
      )
    } catch {
      fail("Unable to start realtime voice: \(error.localizedDescription)")
    }
  }

  public func stop() {
    tearDownConnection(disconnectTransport: true)
    state = .disconnected
  }

  private func tearDownConnection(disconnectTransport: Bool) {
    sessionTask?.cancel()
    microphoneTask?.cancel()
    sessionTask = nil
    microphoneTask = nil
    let transport = self.transport
    let audioController = self.audioController
    self.transport = nil
    self.audioController = nil
    // Audio teardown blocks on default-QoS CoreAudio work (engine stop and
    // AU disposal). Run it detached at utility: a child task inherits the
    // caller's user-initiated priority, and even an explicit utility task on
    // the shared actor gets boosted when user-initiated jobs queue behind it
    // — both trip the priority-inversion diagnostic. The detached task also
    // drops the last controller reference off-actor, keeping deallocation at
    // utility as well.
    Task.detached(priority: .utility) {
      await audioController?.stop()
      if disconnectTransport {
        await transport?.disconnect()
      }
    }
    activeResponseID = nil
    currentAudioItemID = nil
    isResponseCreatePending = false
    isDeliveringBackgroundUpdate = false
    isAwaitingBackgroundWork = false
    isStandbyMuted = false
    allowBargeIn = false
    backgroundUpdates.removeAll()
    microphoneLevel = 0
    assistantLevel = 0
    isAssistantSpeaking = false
    isMicrophoneMuted = false
  }

  public func setMicrophoneMuted(_ isMuted: Bool) {
    // The user took control of the microphone; standby yields either way.
    isStandbyMuted = false
    isMicrophoneMuted = isMuted
    if isMuted {
      microphoneLevel = 0
    }
  }

  /// Signals whether any session completion is being awaited (watchers
  /// active). Engages standby mute on the false→true transition only, so a
  /// user who unmuted mid-wait is not re-muted by repeated signals.
  public func setAwaitingBackgroundWork(_ awaiting: Bool) {
    let wasAwaiting = isAwaitingBackgroundWork
    isAwaitingBackgroundWork = awaiting
    if awaiting, !wasAwaiting, !isMicrophoneMuted {
      isStandbyMuted = true
      microphoneLevel = 0
    }
    if !awaiting {
      isStandbyMuted = false
    }
  }

  /// Releases standby for the current wait without touching the user mute —
  /// the unmute affordance while the engine is standby-muted.
  public func overrideStandbyMute() {
    isStandbyMuted = false
  }

  public func pushBackgroundUpdate(_ update: String) {
    let trimmed = update.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    backgroundUpdates.append(trimmed)
    if backgroundUpdates.count > 5 {
      backgroundUpdates.removeFirst(backgroundUpdates.count - 5)
    }
    flushBackgroundUpdateIfPossible()
  }

  private func beginStreaming(
    transport: any RealtimeTransport,
    audio: any RealtimeAudioControlling,
    tools: VoiceToolRegistry,
    allowBargeIn: Bool
  ) {
    let readyState = RealtimeReadyState()

    microphoneTask = Task { @RealtimeActor [weak self] in
      do {
        let stream = try audio.microphoneStream()
        for await buffer in stream {
          guard !Task.isCancelled else { break }
          // Half-duplex echo gate: while assistant audio is audibly playing,
          // drop mic frames so speaker echo can't trigger turn detection or
          // pollute transcription. Barge-in opts back into full duplex.
          let playbackActive = audio.isPlaybackActive()
          let gatedByPlayback = !allowBargeIn && playbackActive
          let level = gatedByPlayback ? 0 : Self.rms(buffer)
          let muted = await self?.updateAudioActivity(
            microphoneLevel: level,
            playbackActive: playbackActive
          ) ?? true
          if !muted,
             !gatedByPlayback,
             await readyState.get(),
             let encoded = AudioUtils.base64EncodeAudioPCMBuffer(from: buffer) {
            await transport.send(.inputAudio(encoded))
          }
        }
      } catch {
        await self?.handleStreamFailure(error)
      }
    }

    sessionTask = Task { @RealtimeActor [weak self] in
      for await event in transport.events {
        guard !Task.isCancelled else { break }
        await self?.handle(
          event,
          transport: transport,
          audio: audio,
          tools: tools,
          readyState: readyState
        )
      }
    }
  }

  private func handle(
    _ event: OpenAIRealtimeMessage,
    transport: any RealtimeTransport,
    audio: any RealtimeAudioControlling,
    tools: VoiceToolRegistry,
    readyState: RealtimeReadyState
  ) async {
    switch event {
    case .sessionCreated, .sessionUpdated:
      await readyState.set(true)
      state = .idle
      flushBackgroundUpdateIfPossible()
    case .responseCreated(let responseID):
      activeResponseID = responseID
      isResponseCreatePending = false
      state = .thinking
    case .responseAudioDelta(let itemID, _, let delta):
      currentAudioItemID = itemID
      await audio.play(base64Audio: delta, itemID: itemID)
      assistantLevel = Self.pcm16Level(base64: delta)
      isAssistantSpeaking = true
      state = .speaking
    case .responseAudioDone:
      assistantLevel = 0
    case .inputAudioBufferSpeechStarted:
      // Unreachable while the delivery gate holds (no frames reach the
      // server), but if speech was detected the microphone is demonstrably
      // live — never leave the gate stuck on.
      isDeliveringBackgroundUpdate = false
      let audioEndMS = await audio.interruptPlayback()
      if let currentAudioItemID, let audioEndMS {
        await transport.send(
          .truncateAudio(itemID: currentAudioItemID, audioEndMS: audioEndMS)
        )
      }
      currentAudioItemID = nil
      assistantLevel = 0
      isAssistantSpeaking = false
      state = .userSpeaking
    case .responseTranscriptDelta(_, _, let delta),
         .responseTextDelta(_, _, let delta):
      applyTranscript(.assistantDelta(delta))
    case .responseTranscriptDone(_, _, let transcript),
         .responseTextDone(_, _, let transcript):
      applyTranscript(.assistantCompleted(transcript))
    case .inputAudioTranscriptionDelta(_, let delta):
      applyTranscript(.userDelta(delta))
    case .inputAudioTranscriptionCompleted(_, let transcript):
      applyTranscript(.userCompleted(transcript))
    case .inputAudioBufferTranscript(let transcript):
      applyTranscript(.userCompleted(transcript))
    case .responseFunctionCallArgumentsDone(
      let name,
      let arguments,
      let callID,
      _,
      _
    ):
      await executeTool(
        name: name,
        arguments: arguments,
        callID: callID,
        transport: transport,
        tools: tools
      )
    case .responseDone(let responseID, let status, let statusDetails):
      if activeResponseID == responseID {
        activeResponseID = nil
      }
      assistantLevel = 0
      if status == "failed" {
        let detail = Self.responseFailureDetail(statusDetails)
          ?? "Realtime response failed."
        errorMessage = detail
        if Self.isFatalRealtimeError(detail) {
          fail(detail)
          await transport.disconnect()
          tearDownConnection(disconnectTransport: false)
          return
        }
      }
      if case .executingTool = state {
        break
      }
      if activeResponseID != nil || isResponseCreatePending {
        break
      }
      // The turn is fully settled (tool-call continuations included), so an
      // announcement in flight has finished — reopen the microphone before
      // the next queued update re-gates it.
      isDeliveringBackgroundUpdate = false
      state = .idle
      flushBackgroundUpdateIfPossible()
    case .error(let message):
      let detail = message ?? "Unknown realtime error."
      errorMessage = detail
      if Self.isFatalRealtimeError(detail) {
        fail(detail)
        await transport.disconnect()
        tearDownConnection(disconnectTransport: false)
      }
    case .disconnected(let message):
      if let message, !message.isEmpty {
        fail("Realtime connection closed: \(message)")
      } else {
        state = .disconnected
      }
      tearDownConnection(disconnectTransport: false)
    default:
      break
    }
  }

  private func executeTool(
    name: String,
    arguments: String,
    callID: String,
    transport: any RealtimeTransport,
    tools: VoiceToolRegistry
  ) async {
    isMicrophoneMuted = true
    microphoneLevel = 0
    state = .executingTool(name)
    let output = await tools.execute(name: name, arguments: arguments)
    applyTranscript(.tool("\(name): \(output)"))
    await transport.send(.functionOutput(callID: callID, output: output))
    await transport.send(.responseCreate)
    isResponseCreatePending = true
    isMicrophoneMuted = false
    state = .thinking
  }

  private func applyTranscript(_ event: VoiceTranscriptEvent) {
    reducer.reduce(event)
    transcripts = reducer.entries
  }

  private func updateAudioActivity(
    microphoneLevel: Float,
    playbackActive: Bool
  ) -> Bool {
    let silenced = isDeliveringBackgroundUpdate || isStandbyMuted
    self.microphoneLevel = silenced ? 0 : microphoneLevel
    // Mic buffers are the heartbeat (~50ms): they keep this true for the
    // whole audible response and flip it off when the playback queue drains.
    isAssistantSpeaking = playbackActive
    return isMicrophoneMuted || silenced
  }

  private func flushBackgroundUpdateIfPossible() {
    guard activeResponseID == nil,
          state == .idle,
          !backgroundUpdates.isEmpty,
          let transport else {
      return
    }
    let update = backgroundUpdates.removeFirst()
    // Barge-in users opted into interrupting the assistant, and that
    // includes cutting off an announcement — only gate for everyone else.
    if !allowBargeIn {
      isDeliveringBackgroundUpdate = true
    }
    state = .thinking
    isResponseCreatePending = true
    Task { @RealtimeActor in
      await transport.send(.backgroundUpdate(update))
      await transport.send(.responseCreate)
    }
  }

  private func fail(_ message: String) {
    errorMessage = message
    state = .failed(message)
    isDeliveringBackgroundUpdate = false
  }

  private func handleStreamFailure(_ error: any Error) {
    fail("Microphone stream failed: \(error.localizedDescription)")
    tearDownConnection(disconnectTransport: true)
  }

  private nonisolated static func responseFailureDetail(
    _ response: [String: OpenAIJSONValue]?
  ) -> String? {
    if let statusDetails = objectValue(response?["status_details"]),
       let error = objectValue(statusDetails["error"]) {
      let code = stringValue(error["code"])
      let message = stringValue(error["message"])

      if let code, let message {
        return "\(code): \(message)"
      }
      return message ?? code
    }

    return statusDetail(response)
  }

  private nonisolated static func objectValue(
    _ value: OpenAIJSONValue?
  ) -> [String: OpenAIJSONValue]? {
    guard case .object(let object) = value else { return nil }
    return object
  }

  private nonisolated static func stringValue(
    _ value: OpenAIJSONValue?
  ) -> String? {
    guard case .string(let string) = value else { return nil }
    return string
  }

  private nonisolated static func statusDetail(
    _ details: [String: OpenAIJSONValue]?
  ) -> String? {
    guard let details,
          let data = try? JSONEncoder().encode(details) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private nonisolated static func isFatalRealtimeError(_ message: String) -> Bool {
    let lowercase = message.lowercased()
    return lowercase.contains("insufficient_quota")
      || lowercase.contains("invalid_api_key")
      || lowercase.contains("invalid api key")
  }

  nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }
    if let values = buffer.floatChannelData?[0] {
      var sum: Float = 0
      for index in 0..<count {
        sum += values[index] * values[index]
      }
      return min(1, sqrt(sum / Float(count)) * 5)
    }
    // The microphone vendor delivers PCM16 buffers, which expose only
    // int16ChannelData — without this branch the level meter reads 0.
    if let values = buffer.int16ChannelData?[0] {
      var sum: Float = 0
      for index in 0..<count {
        let sample = Float(values[index]) / Float(Int16.max)
        sum += sample * sample
      }
      return min(1, sqrt(sum / Float(count)) * 5)
    }
    return 0
  }

  private nonisolated static func pcm16Level(base64: String) -> Float {
    guard let data = Data(base64Encoded: base64), data.count >= 2 else {
      return 0
    }
    let sampleCount = data.count / 2
    var sum: Float = 0
    data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      for index in 0..<sampleCount {
        let offset = index * 2
        let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        let sample = Float(Int16(bitPattern: bits)) / Float(Int16.max)
        sum += sample * sample
      }
    }
    return min(1, sqrt(sum / Float(sampleCount)) * 5)
  }
}
