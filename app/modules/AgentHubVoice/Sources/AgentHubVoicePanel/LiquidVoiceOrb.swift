import AgentHubVoice
import SwiftUI

/// Shader drive parameters for the liquid voice orb: how bright the liquid
/// field burns and how fast it flows. Resolved purely from engine activity so
/// the mapping is unit-testable.
struct LiquidOrbActivity: Equatable {
  var intensity: Double
  var speed: Double

  static func resolve(
    state: VoiceEngineState,
    isAssistantSpeaking: Bool,
    microphoneLevel: Float,
    assistantLevel: Float
  ) -> LiquidOrbActivity {
    // Audible playback outlasts the engine's speaking state (levels track
    // network delta arrival), so the flag wins over the state machine.
    if isAssistantSpeaking {
      return LiquidOrbActivity(
        intensity: clamped(0.78 + Double(assistantLevel) * 0.22),
        speed: 1.7
      )
    }
    switch state {
    case .disconnected, .failed:
      return LiquidOrbActivity(intensity: 0.16, speed: 0.35)
    case .connecting:
      return LiquidOrbActivity(intensity: 0.3, speed: 0.6)
    case .idle:
      return LiquidOrbActivity(
        intensity: clamped(0.42 + Double(microphoneLevel) * 0.15),
        speed: 0.8
      )
    case .userSpeaking:
      // The user's own voice should read as a gentle glow, not a light show —
      // the orb's opacity dip is the primary listening cue.
      return LiquidOrbActivity(
        intensity: clamped(0.6 + Double(microphoneLevel) * 0.15),
        speed: 1.05
      )
    case .thinking:
      return LiquidOrbActivity(intensity: 0.55, speed: 1.5)
    case .speaking:
      return LiquidOrbActivity(
        intensity: clamped(0.78 + Double(assistantLevel) * 0.22),
        speed: 1.7
      )
    case .executingTool:
      return LiquidOrbActivity(intensity: 0.5, speed: 1.2)
    }
  }

  private static func clamped(_ value: Double) -> Double {
    min(max(value, 0), 1)
  }
}

/// Accumulates shader phase across frames so speed changes never jump the
/// pattern: `time * speed` with a large absolute time hard-cuts the visual on
/// every speed change, while integrated phase stays continuous. Intensity and
/// speed are low-pass filtered toward their targets for the same reason.
/// Mutated from `TimelineView` render passes; deliberately not observable.
final class LiquidOrbClock {
  private var lastDate: Date?
  private(set) var phase: Double = 0
  private(set) var smoothedIntensity: Double = 0
  private(set) var smoothedSpeed: Double = 0

  /// Time constant ~0.16s: fast enough to feel live, slow enough to glide.
  private let smoothingRate: Double = 6

  func advance(
    to date: Date,
    target: LiquidOrbActivity
  ) -> (time: Double, intensity: Double) {
    let elapsed = lastDate.map { date.timeIntervalSince($0) } ?? 0
    lastDate = date
    // Frame gaps (window hidden, debugger pauses) must not fast-forward the
    // pattern or snap the smoothing.
    let dt = min(max(elapsed, 0), 1.0 / 15.0)
    let alpha = 1 - exp(-dt * smoothingRate)
    smoothedIntensity += (target.intensity - smoothedIntensity) * alpha
    smoothedSpeed += (target.speed - smoothedSpeed) * alpha
    phase += dt * smoothedSpeed
    return (phase, smoothedIntensity)
  }
}

/// The liquid core of the conversation orb: a dark disc with ShaderKit's
/// liquid-tech field flowing through it, tinted with the selected voice's
/// gradient and burning brighter while the user or assistant is speaking.
struct LiquidVoiceOrb: View {
  let activity: LiquidOrbActivity
  let colors: [Color]
  let diameter: CGFloat

  @State private var clock = LiquidOrbClock()

  private var colorA: Color { colors.first ?? .blue }
  private var colorB: Color { colors.count > 1 ? colors[1] : colorA }

  var body: some View {
    TimelineView(.animation(minimumInterval: nil, paused: activity.speed == 0)) { context in
      let sample = clock.advance(to: context.date, target: activity)
      Circle()
        .fill(
          LinearGradient(
            colors: [
              Color(red: 0.06, green: 0.07, blue: 0.10),
              Color(red: 0.03, green: 0.04, blue: 0.06),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .layerEffect(
          ShaderLibrary.bundle(.module).liquidVoiceOrb(
            .float2(diameter, diameter),
            .float(sample.time),
            .float(sample.intensity),
            .color(colorA),
            .color(colorB)
          ),
          maxSampleOffset: .zero
        )
    }
    .frame(width: diameter, height: diameter)
  }
}
