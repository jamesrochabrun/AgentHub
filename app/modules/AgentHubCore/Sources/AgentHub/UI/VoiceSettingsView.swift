import AgentHubVoice
import AgentHubVoicePanel
import SwiftUI

public struct VoiceSettingsView: View {
  @Environment(\.agentHub) private var agentHub
  @State private var apiKey = ""
  @State private var keySource: OpenAIKeySource?
  @State private var saveMessage: String?
  @State private var isSaving = false

  @AppStorage(AgentHubDefaults.voiceEnabled)
  private var voiceEnabled = true

  @AppStorage(AgentHubDefaults.voiceAutoSubmitDictation)
  private var autoSubmitDictation = true

  @AppStorage(AgentHubDefaults.voiceRealtimeModel)
  private var realtimeModel = "gpt-realtime"

  @AppStorage(AgentHubDefaults.voiceName)
  private var voiceName = "marin"

  @AppStorage(AgentHubDefaults.voiceVADEagerness)
  private var vadEagerness = "medium"

  @AppStorage(AgentHubDefaults.voiceDictationModel)
  private var dictationModel = "whisper-1"

  @AppStorage(AgentHubDefaults.voiceScreenCaptureEnabled)
  private var screenCaptureEnabled = true

  @AppStorage(AgentHubDefaults.voiceLanguage)
  private var language = "auto"

  @AppStorage(AgentHubDefaults.voiceAllowBargeIn)
  private var allowBargeIn = false

  @AppStorage(AgentHubDefaults.voiceShowTranscript)
  private var showTranscript = false

  @State private var showsOnboarding = false
  @State private var mcpServers: [VoiceMCPServerDescriptor] = []
  @State private var enabledMCPServers: Set<String> = []

  public init() {}

  public var body: some View {
    Form {
      VoiceAPIKeySettingsSection(
        apiKey: $apiKey,
        keySource: keySource,
        saveMessage: saveMessage,
        isSaving: isSaving,
        onSave: saveAPIKey
      )

      VoiceBehaviorSettingsSection(
        voiceEnabled: $voiceEnabled,
        autoSubmitDictation: $autoSubmitDictation,
        screenCaptureEnabled: $screenCaptureEnabled,
        allowBargeIn: $allowBargeIn,
        showTranscript: $showTranscript,
        registrationError: agentHub?
          .voiceControlCoordinator
          .registrationErrorMessage,
        onShowOnboarding: { showsOnboarding = true }
      )

      VoiceMCPToolsSettingsSection(
        servers: mcpServers,
        isEnabled: { enabledMCPServers.contains($0.name) },
        onToggle: setMCPServer
      )

      VoiceRealtimeSettingsSection(
        realtimeModel: $realtimeModel,
        voiceName: $voiceName,
        vadEagerness: $vadEagerness,
        dictationModel: $dictationModel,
        language: $language
      )
    }
    .formStyle(.grouped)
    .task {
      await loadAPIKey()
      await loadMCPServers()
    }
    .onChange(of: voiceEnabled) { _, enabled in
      agentHub?.voiceControlCoordinator.setEnabled(enabled)
    }
    .sheet(isPresented: $showsOnboarding) {
      VoiceOnboardingView(
        configuration: .agentHub,
        onDismiss: { showsOnboarding = false }
      )
    }
  }

  private func loadAPIKey() async {
    guard let provider = agentHub?.openAIKeyProvider else { return }
    do {
      let resolution = try await provider.resolve()
      keySource = resolution?.source
      apiKey = resolution?.source == .keychain ? resolution?.key ?? "" : ""
      saveMessage = nil
    } catch {
      saveMessage = error.localizedDescription
    }
  }

  private func loadMCPServers() async {
    enabledMCPServers = Set(
      UserDefaults.standard.stringArray(
        forKey: AgentHubDefaults.voiceMCPEnabledServers
      ) ?? []
    )
    mcpServers = await agentHub?.voiceMCPToolProvider.discoverServers() ?? []
  }

  private func setMCPServer(_ server: VoiceMCPServerDescriptor, enabled: Bool) {
    if enabled {
      enabledMCPServers.insert(server.name)
    } else {
      enabledMCPServers.remove(server.name)
    }
    UserDefaults.standard.set(
      enabledMCPServers.sorted(),
      forKey: AgentHubDefaults.voiceMCPEnabledServers
    )
    agentHub?.voiceMCPToolProvider.scheduleRefresh()
  }

  private func saveAPIKey() {
    guard let provider = agentHub?.openAIKeyProvider else { return }
    isSaving = true
    saveMessage = nil
    Task {
      do {
        try await provider.save(apiKey)
        await loadAPIKey()
        saveMessage = apiKey.isEmpty ? "Stored key removed." : "Saved in Keychain."
      } catch {
        saveMessage = error.localizedDescription
      }
      isSaving = false
    }
  }
}
