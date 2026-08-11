import SwiftOpenAI

public enum OpenAIClientFactory {
  public static func service(apiKey: String) -> any OpenAIService {
    OpenAIServiceFactory.service(apiKey: apiKey)
  }
}

public final class OpenAIClient: @unchecked Sendable {
  private let service: any OpenAIService

  public init(apiKey: String) {
    service = OpenAIClientFactory.service(apiKey: apiKey)
  }

  public func transcriptionService() -> any TranscriptionService {
    OpenAITranscriptionAdapter(service: service)
  }

  @MainActor
  public func startRealtime(
    engine: RealtimeVoiceEngine,
    settings: VoiceEngineSettings,
    tools: VoiceToolRegistry
  ) async {
    await engine.start(service: service, settings: settings, tools: tools)
  }
}
