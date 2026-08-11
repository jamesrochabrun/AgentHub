import AgentHubVoice
import Foundation
import Observation

public enum VoiceHUDMode: String, CaseIterable, Sendable {
  case dictate
  case converse

  public var label: String {
    switch self {
    case .dictate:
      "Dictate"
    case .converse:
      "Converse"
    }
  }
}

@Observable
@MainActor
public final class VoiceHUDViewModel {
  public var mode: VoiceHUDMode
  public var manualTargetId: String?
  public private(set) var dictationController: DictationController?
  public private(set) var dictationTranscripts: [VoiceTranscriptEntry] = []
  public private(set) var localErrorMessage: String?

  public let configuration: VoiceHUDConfiguration

  private let host: any VoiceHUDHost
  private let engine: RealtimeVoiceEngine
  private let defaults: UserDefaults

  public init(
    host: any VoiceHUDHost,
    engine: RealtimeVoiceEngine,
    configuration: VoiceHUDConfiguration,
    defaults: UserDefaults = .standard
  ) {
    self.host = host
    self.engine = engine
    self.configuration = configuration
    self.defaults = defaults
    mode = VoiceHUDMode(
      rawValue: defaults.string(forKey: configuration.settings.mode) ?? ""
    ) ?? .dictate
  }

  public var targets: [VoiceHUDTarget] {
    host.targets
  }

  public var target: VoiceHUDTarget? {
    host.resolveTarget(manualId: manualTargetId)
  }

  public var realtimeState: VoiceEngineState {
    engine.state
  }

  public var microphoneLevel: Float {
    switch mode {
    case .dictate:
      dictationController?.audioLevel ?? 0
    case .converse:
      engine.microphoneLevel
    }
  }

  public var assistantLevel: Float {
    switch mode {
    case .dictate:
      0
    case .converse:
      engine.assistantLevel
    }
  }

  public var dictationState: DictationState {
    dictationController?.state ?? .idle
  }

  public var isActive: Bool {
    switch mode {
    case .dictate:
      dictationController?.state == .recording
        || dictationController?.state == .transcribing
    case .converse:
      switch realtimeState {
      case .disconnected, .failed:
        false
      default:
        true
      }
    }
  }

  public var transcripts: [VoiceTranscriptEntry] {
    switch mode {
    case .dictate:
      dictationTranscripts
    case .converse:
      engine.transcripts
    }
  }

  public var errorMessage: String? {
    if let localErrorMessage {
      return localErrorMessage
    }
    if let dictationController,
       case .failed(let message) = dictationController.state {
      return message
    }
    return engine.errorMessage
  }

  public func handleModeChange() {
    defaults.set(mode.rawValue, forKey: configuration.settings.mode)
    localErrorMessage = nil
    switch mode {
    case .dictate:
      engine.stop()
    case .converse:
      dictationController?.cancel()
    }
  }

  public func selectTarget(_ sessionId: String?) {
    manualTargetId = sessionId
  }

  public func toggleMicrophone() {
    Task {
      switch mode {
      case .dictate:
        await toggleDictation()
      case .converse:
        await toggleConversation()
      }
    }
  }

  public func stopAllAudio() {
    dictationController?.cancel()
    engine.stop()
  }

  private func toggleDictation() async {
    engine.stop()
    if dictationController == nil {
      guard let service = await makeService() else { return }
      let model = defaults.string(
        forKey: configuration.settings.dictationModel
      ) ?? "whisper-1"
      let controller = DictationController(
        transcriptionService: service.transcriptionService(),
        model: model
      )
      controller.onTranscript = { [weak self] transcript in
        self?.handleTranscript(transcript)
      }
      dictationController = controller
    }
    await dictationController?.toggle()
  }

  private func toggleConversation() async {
    dictationController?.cancel()
    switch engine.state {
    case .disconnected, .failed:
      guard let service = await makeService() else { return }
      let storedLanguage = defaults.string(
        forKey: configuration.settings.language
      )
      let settings = VoiceEngineSettings(
        model: defaults.string(
          forKey: configuration.settings.realtimeModel
        ) ?? "gpt-realtime",
        voiceName: defaults.string(
          forKey: configuration.settings.voiceName
        ) ?? "marin",
        vadEagerness: defaults.string(
          forKey: configuration.settings.vadEagerness
        ) ?? "medium",
        dictationModel: defaults.string(
          forKey: configuration.settings.dictationModel
        ) ?? "whisper-1",
        language: storedLanguage == "auto" ? nil : storedLanguage,
        allowBargeIn: defaults.bool(
          forKey: configuration.settings.allowBargeIn
        )
      )
      await service.startRealtime(
        engine: engine,
        settings: settings,
        tools: host.makeToolRegistry()
      )
    default:
      engine.stop()
    }
  }

  private func makeService() async -> OpenAIClient? {
    do {
      guard let key = try await host.resolveAPIKey() else {
        localErrorMessage =
          "Add an OpenAI API key in \(configuration.productName) settings."
        return nil
      }
      localErrorMessage = nil
      return OpenAIClient(apiKey: key)
    } catch {
      localErrorMessage = error.localizedDescription
      return nil
    }
  }

  private func handleTranscript(_ transcript: String) {
    dictationTranscripts.append(
      VoiceTranscriptEntry(role: .user, text: transcript)
    )
    if dictationTranscripts.count > 6 {
      dictationTranscripts.removeFirst(dictationTranscripts.count - 6)
    }
    guard let target else {
      localErrorMessage = "Choose a session before dictating."
      return
    }

    switch host.deliverDictation(transcript, to: target.id) {
    case .delivered:
      break
    case .failed(let message):
      localErrorMessage = message
    }
  }
}
