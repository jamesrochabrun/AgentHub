//
//  AgentHubVoiceHUDHost.swift
//  AgentHub
//
//  Bridges the reusable voice HUD (AgentHubVoicePanel) to AgentHub's sessions:
//  targets come from the session target resolver, tools from the voice tool
//  catalog, and dictation is delivered through the session terminals.
//

import AgentHubVoice
import Foundation

extension VoiceHUDConfiguration {
  public static let agentHub = VoiceHUDConfiguration(
    productName: "AgentHub",
    settings: VoiceHUDSettingsKeys(
      mode: AgentHubDefaults.voiceMode,
      realtimeModel: AgentHubDefaults.voiceRealtimeModel,
      voiceName: AgentHubDefaults.voiceName,
      vadEagerness: AgentHubDefaults.voiceVADEagerness,
      dictationModel: AgentHubDefaults.voiceDictationModel,
      language: AgentHubDefaults.voiceLanguage,
      allowBargeIn: AgentHubDefaults.voiceAllowBargeIn,
      hudFrame: AgentHubDefaults.voiceHUDFrame,
      screenCaptureEnabled: AgentHubDefaults.voiceScreenCaptureEnabled,
      onboardingCompleted: AgentHubDefaults.voiceOnboardingCompleted
    )
  )
}

@MainActor
public final class AgentHubVoiceHUDHost: VoiceHUDHost {
  private weak var provider: AgentHubProvider?
  private let defaults: UserDefaults

  public init(
    provider: AgentHubProvider,
    defaults: UserDefaults = .standard
  ) {
    self.provider = provider
    self.defaults = defaults
  }

  public var targets: [VoiceHUDTarget] {
    provider?.voiceSessionTargetResolver
      .candidates()
      .sorted { $0.lastActivityAt > $1.lastActivityAt }
      .map(Self.hudTarget)
      ?? []
  }

  public func resolveTarget(manualId: String?) -> VoiceHUDTarget? {
    provider?.voiceSessionTargetResolver
      .resolve(manualSessionId: manualId)
      .map(Self.hudTarget)
  }

  public func makeToolRegistry() -> VoiceToolRegistry {
    VoiceToolRegistry(
      tools: provider?.voiceToolCatalog.makeTools() ?? []
    )
  }

  public func resolveAPIKey() async throws -> String? {
    guard let provider else { return nil }
    return try await provider.openAIKeyProvider.resolve()?.key
  }

  public func deliverDictation(
    _ transcript: String,
    to targetId: String
  ) -> VoiceDictationOutcome {
    guard let provider,
          let target = provider.voiceSessionTargetResolver
            .resolve(manualSessionId: targetId) else {
      return .failed("The selected session is no longer available.")
    }

    if defaults.bool(forKey: AgentHubDefaults.voiceAutoSubmitDictation) {
      let result = provider.voiceToolExecutor.sendPrompt(
        sessionId: target.sessionId,
        prompt: transcript
      )
      return result.status == "accepted"
        ? .delivered
        : .failed("The selected session is no longer available.")
    }

    let viewModel = target.provider == .claude
      ? provider.claudeSessionsViewModel
      : provider.codexSessionsViewModel
    if viewModel.typeTextInActiveTerminal(
      forKey: target.sessionId,
      text: transcript
    ) {
      return .delivered
    }
    return .failed("Focus this session's terminal before inserting text.")
  }

  private static func hudTarget(_ target: VoiceSessionTarget) -> VoiceHUDTarget {
    VoiceHUDTarget(
      id: target.sessionId,
      name: target.name,
      detail: target.provider.rawValue
    )
  }
}
