import AgentHubVoice
import SwiftUI

/// Occupies the transcript area when transcript text is hidden: the selected
/// voice's orb in converse mode, an animated dictation symbol in dictate mode.
struct VoiceActivityVisualizer: View {
  let mode: VoiceHUDMode
  let voiceId: String
  let realtimeState: VoiceEngineState
  let dictationState: DictationState
  let microphoneLevel: Float
  let assistantLevel: Float
  var accentColor: Color?

  private var voice: VoiceOption {
    VoiceOption.all.first { $0.id == voiceId } ?? VoiceOption.all[0]
  }

  var body: some View {
    Group {
      switch mode {
      case .converse:
        VoiceConversationOrb(
          voice: voice,
          state: realtimeState,
          microphoneLevel: microphoneLevel,
          assistantLevel: assistantLevel
        )
      case .dictate:
        VoiceDictationIndicator(
          state: dictationState,
          level: microphoneLevel,
          accentColor: accentColor
        )
      }
    }
    .frame(minHeight: 140, maxHeight: .infinity)
  }
}
