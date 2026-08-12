import AgentHubVoice
import SwiftUI

public struct VoiceHUDView: View {
  @State private var viewModel: VoiceHUDViewModel
  @State private var showsOnboarding = false
  @AppStorage private var showsTranscript: Bool
  @AppStorage private var selectedVoiceId: String

  let onClose: () -> Void

  public init(
    viewModel: VoiceHUDViewModel,
    onClose: @escaping () -> Void = {}
  ) {
    _viewModel = State(initialValue: viewModel)
    _showsTranscript = AppStorage(
      wrappedValue: false,
      viewModel.configuration.settings.showTranscript
    )
    _selectedVoiceId = AppStorage(
      wrappedValue: VoiceOption.all[0].id,
      viewModel.configuration.settings.voiceName
    )
    self.onClose = onClose
  }

  public var body: some View {
    VStack(spacing: 12) {
      VoiceHUDHeader(
        productName: viewModel.configuration.productName,
        onClose: onClose
      )

      VoiceModeToggle(
        mode: $viewModel.mode,
        accentColor: viewModel.configuration.accentColor
      )

      VoiceTargetChip(
        target: viewModel.target,
        targets: viewModel.targets,
        onSelect: viewModel.selectTarget
      )

      if showsTranscript {
        VoiceTranscriptList(entries: viewModel.transcripts)
      } else {
        VoiceActivityVisualizer(
          mode: viewModel.mode,
          voiceId: selectedVoiceId,
          realtimeState: viewModel.realtimeState,
          dictationState: viewModel.dictationState,
          isAssistantSpeaking: viewModel.isAssistantSpeaking,
          microphoneLevel: viewModel.microphoneLevel,
          assistantLevel: viewModel.assistantLevel,
          accentColor: viewModel.configuration.accentColor
        )
      }

      if let errorMessage = viewModel.errorMessage {
        VoiceHUDErrorBanner(message: errorMessage)
      }

      if viewModel.mode == .converse, viewModel.isActive {
        Text(converseStatusCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      controlBar
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .voiceHUDChrome()
    .onChange(of: viewModel.mode) { _, _ in
      viewModel.handleModeChange()
    }
    .onDisappear {
      viewModel.stopAllAudio()
    }
    .onAppear {
      showsOnboarding = !UserDefaults.standard.bool(
        forKey: viewModel.configuration.settings.onboardingCompleted
      )
    }
    .sheet(isPresented: $showsOnboarding) {
      VoiceOnboardingView(
        configuration: viewModel.configuration,
        onStartVoiceChat: {
          viewModel.mode = .converse
          viewModel.toggleMicrophone()
        },
        onDismiss: {
          showsOnboarding = false
        }
      )
    }
  }

  /// Primary start/end control centered, with the mute toggle beside it
  /// while a conversation is live.
  private var controlBar: some View {
    ZStack {
      VoiceMicButton(
        mode: viewModel.mode,
        state: viewModel.realtimeState,
        isActive: viewModel.isActive,
        level: viewModel.microphoneLevel,
        productName: viewModel.configuration.productName,
        action: viewModel.toggleMicrophone
      )

      if viewModel.mode == .converse, viewModel.isActive {
        HStack {
          Spacer()
          VoiceMuteButton(
            isMuted: viewModel.isMicrophoneMuted,
            isGated: viewModel.isMicrophoneGated,
            isStandby: viewModel.isMicrophoneStandbyMuted,
            action: viewModel.toggleMicrophoneMute
          )
        }
        .padding(.trailing, 24)
      }
    }
  }

  private var converseStatusCaption: String {
    if viewModel.isMicrophoneGated {
      return "Sharing an update…"
    }
    if viewModel.isMicrophoneStandbyMuted {
      return "Muted while waiting — tap the mic to talk"
    }
    switch viewModel.realtimeState {
    case .connecting:
      return "Connecting…"
    case .idle:
      return viewModel.isMicrophoneMuted ? "Muted" : "Listening"
    case .userSpeaking:
      return "You're speaking"
    case .thinking:
      return "Thinking…"
    case .speaking:
      return "\(viewModel.configuration.productName) is speaking"
    case .executingTool(let name):
      return "Running \(name)"
    case .disconnected, .failed:
      return ""
    }
  }
}
