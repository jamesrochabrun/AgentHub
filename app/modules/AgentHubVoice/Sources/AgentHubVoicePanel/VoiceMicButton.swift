import AgentHubVoice
import SwiftUI

struct VoiceMicButton: View {
  let mode: VoiceHUDMode
  let state: VoiceEngineState
  let isActive: Bool
  let level: Float
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .stroke(Color.accentColor.opacity(0.25), lineWidth: 7)
          .scaleEffect(1 + CGFloat(level) * 0.16)

        Circle()
          .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))

        Image(systemName: icon)
          .font(.title2)
          .foregroundStyle(isActive ? .white : .primary)
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

  private var icon: String {
    if case .executingTool = state {
      return "gearshape.fill"
    }
    return isActive ? "stop.fill" : "mic.fill"
  }

  private var accessibilityLabel: String {
    isActive ? "Stop \(mode.label)" : "Start \(mode.label)"
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
      "AgentHub is speaking"
    case .executingTool(let name):
      "Running \(name)"
    case .failed(let message):
      message
    }
  }
}
