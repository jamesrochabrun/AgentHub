import SwiftUI

/// Mute toggle shown beside the primary button during a conversation.
/// Reflects everything that silences the microphone: the user's manual mute
/// and the engine's transient delivery gate (a session announcement in
/// flight) — the mic must never look hot while the engine drops its frames.
struct VoiceMuteButton: View {
  let isMuted: Bool
  let isGated: Bool
  let isStandby: Bool
  let action: () -> Void

  enum DisplayState: Equatable {
    /// Microphone is live and streaming.
    case live
    /// The user muted the microphone; persists until they unmute.
    case userMuted
    /// The engine paused the microphone while delivering an announcement;
    /// clears itself when the announcement finishes.
    case gated
    /// The engine auto-muted while awaiting a session completion; tapping
    /// unmutes for the current wait.
    case standby

    static func make(
      isMuted: Bool,
      isGated: Bool,
      isStandby: Bool
    ) -> DisplayState {
      // The user's mute wins: it outlives both automatic pauses, and tapping
      // the button in this state must read as "unmute", not as overriding
      // the engine. The delivery gate outranks standby — an announcement in
      // flight is the more specific reason the mic is closed.
      if isMuted { return .userMuted }
      if isGated { return .gated }
      if isStandby { return .standby }
      return .live
    }
  }

  private var displayState: DisplayState {
    .make(isMuted: isMuted, isGated: isGated, isStandby: isStandby)
  }

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(fillColor)

        Image(systemName: icon)
          .font(.callout)
          .foregroundStyle(iconColor)
      }
      .frame(width: 36, height: 36)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }

  private var icon: String {
    displayState == .live ? "mic.fill" : "mic.slash.fill"
  }

  private var fillColor: Color {
    switch displayState {
    case .live:
      Color.secondary.opacity(0.2)
    case .userMuted:
      Color.red
    case .gated, .standby:
      Color.secondary.opacity(0.35)
    }
  }

  private var iconColor: Color {
    displayState == .userMuted ? .white : .primary
  }

  private var accessibilityLabel: String {
    switch displayState {
    case .live:
      "Mute microphone"
    case .userMuted, .standby:
      "Unmute microphone"
    case .gated:
      "Mute microphone"
    }
  }

  private var accessibilityValue: String {
    switch displayState {
    case .live:
      "Microphone on"
    case .userMuted:
      "Muted"
    case .gated:
      "Paused while sharing an update"
    case .standby:
      "Muted while waiting for a session"
    }
  }
}
