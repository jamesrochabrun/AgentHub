import AgentHubVoice
import SwiftUI

/// The dictate-mode visualizer: an animated SF Symbol that ripples while
/// recording, pulses while transcribing, and rests dimmed when idle.
struct VoiceDictationIndicator: View {
  let state: DictationState
  let level: Float
  var accentColor: Color?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isRecording: Bool {
    state == .recording
  }

  private var isTranscribing: Bool {
    state == .transcribing
  }

  private var symbolName: String {
    switch state {
    case .recording:
      "waveform"
    case .transcribing:
      "ellipsis"
    case .idle, .failed:
      "mic"
    }
  }

  private var caption: String {
    switch state {
    case .recording:
      "Listening…"
    case .transcribing:
      "Transcribing…"
    case .idle, .failed:
      "Ready to listen"
    }
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbolName)
        .font(.system(size: 44, weight: .light))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(
          isRecording ? (accentColor ?? .accentColor) : Color.secondary
        )
        .symbolEffect(
          .variableColor.iterative,
          options: .repeating,
          isActive: isRecording && !reduceMotion
        )
        .symbolEffect(
          .pulse,
          options: .repeating,
          isActive: isTranscribing && !reduceMotion
        )
        .scaleEffect(isRecording ? 1 + CGFloat(level) * 0.2 : 1)
        .animation(.smooth(duration: 0.15), value: level)
        .contentTransition(.symbolEffect(.replace))

      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.smooth(duration: 0.25), value: symbolName)
    .accessibilityElement()
    .accessibilityLabel(caption)
  }
}
