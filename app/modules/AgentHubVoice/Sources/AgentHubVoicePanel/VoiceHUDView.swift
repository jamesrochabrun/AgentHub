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
          microphoneLevel: viewModel.microphoneLevel,
          assistantLevel: viewModel.assistantLevel,
          accentColor: viewModel.configuration.accentColor
        )
      }

      if let errorMessage = viewModel.errorMessage {
        VoiceHUDErrorBanner(message: errorMessage)
      }

      VoiceMicButton(
        mode: viewModel.mode,
        state: viewModel.realtimeState,
        isActive: viewModel.isActive,
        level: viewModel.microphoneLevel,
        action: viewModel.toggleMicrophone
      )
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
}
