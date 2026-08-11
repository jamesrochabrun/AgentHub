import AgentHubVoice
import SwiftUI

/// The converse-mode visualizer: an orb in the selected voice's gradient that
/// swells with whoever is louder (user or assistant), breathes gently while
/// idle, and dims while disconnected.
struct VoiceConversationOrb: View {
  let voice: VoiceOption
  let state: VoiceEngineState
  let microphoneLevel: Float
  let assistantLevel: Float

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isBreathing = false

  private var level: CGFloat {
    CGFloat(max(microphoneLevel, assistantLevel))
  }

  private var isConnected: Bool {
    switch state {
    case .disconnected, .failed:
      false
    default:
      true
    }
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [voice.gradient.first?.opacity(0.45) ?? .clear, .clear],
            center: .center,
            startRadius: 10,
            endRadius: 90
          )
        )
        .frame(width: 180, height: 180)
        .scaleEffect(haloScale)

      Circle()
        .fill(
          LinearGradient(
            colors: voice.gradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: 104, height: 104)
        .overlay {
          Circle()
            .fill(
              RadialGradient(
                colors: [Color.white.opacity(0.35), .clear],
                center: .init(x: 0.3, y: 0.25),
                startRadius: 2,
                endRadius: 60
              )
            )
        }
        .scaleEffect(coreScale)
        .opacity(isConnected ? 1 : 0.45)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.smooth(duration: 0.15), value: level)
    .animation(.smooth(duration: 0.3), value: isConnected)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
        isBreathing = true
      }
    }
    .accessibilityElement()
    .accessibilityLabel("\(voice.title) voice activity")
  }

  private var breathScale: CGFloat {
    isBreathing ? 1.04 : 1.0
  }

  private var coreScale: CGFloat {
    guard isConnected else { return 1 }
    return breathScale + level * 0.22
  }

  private var haloScale: CGFloat {
    guard isConnected else { return 0.9 }
    return breathScale + level * 0.5
  }
}
