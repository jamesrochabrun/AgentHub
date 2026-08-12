import AgentHubVoice
import SwiftUI

struct VoiceMicButton: View {
  let mode: VoiceHUDMode
  let state: VoiceEngineState
  let isActive: Bool
  let level: Float
  let productName: String
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      ZStack {
        // The original halo ring, blurred into a soft glow — drawn behind
        // the fill so it bleeds out from the button's edge, breathing with
        // the mic level.
        Circle()
          .stroke(Color.accentColor.opacity(0.35), lineWidth: 9)
          .blur(radius: 5 + CGFloat(level) * 5)
          .scaleEffect(1 + CGFloat(level) * 0.16)

        Circle()
          .fill(Color.secondary.opacity(0.2))

        Image(systemName: icon)
          .font(.title2)
          .foregroundStyle(.primary)
      }
      .frame(width: 64, height: 64)
      .animation(
        .easeOut(duration: reduceMotion ? 0.01 : 0.12),
        value: level
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(stateDescription)
  }

  // Dictate is a recording (mic → stop); converse is a live session, so its
  // active state reads as "close the session", not "stop recording".
  private var icon: String {
    if case .executingTool = state {
      return "gearshape.fill"
    }
    switch mode {
    case .dictate:
      return isActive ? "stop.fill" : "mic.fill"
    case .converse:
      return isActive ? "xmark" : "waveform"
    }
  }

  private var accessibilityLabel: String {
    switch mode {
    case .dictate:
      isActive ? "Stop dictation" : "Start dictation"
    case .converse:
      isActive ? "End conversation" : "Start conversation"
    }
  }

  private var stateDescription: String {
    switch state {
    case .disconnected:
      "Disconnected"
    case .connecting:
      "Connecting"
    case .idle:
      "Listening"
    case .userSpeaking:
      "You are speaking"
    case .thinking:
      "Thinking"
    case .speaking:
      "\(productName) is speaking"
    case .executingTool(let name):
      "Running \(name)"
    case .failed(let message):
      message
    }
  }
}
