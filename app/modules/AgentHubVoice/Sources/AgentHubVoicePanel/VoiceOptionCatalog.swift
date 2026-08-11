import SwiftUI

/// Realtime API voices offered in onboarding and Voice settings.
public struct VoiceOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let tagline: String
  public let gradient: [Color]

  public static let all: [VoiceOption] = [
    VoiceOption(
      id: "marin",
      title: "Marin",
      tagline: "Warm and steady",
      gradient: [.blue, .cyan]
    ),
    VoiceOption(
      id: "cedar",
      title: "Cedar",
      tagline: "Calm and grounded",
      gradient: [.green, .teal]
    ),
    VoiceOption(
      id: "alloy",
      title: "Alloy",
      tagline: "Balanced and clear",
      gradient: [.gray, .blue]
    ),
    VoiceOption(
      id: "ash",
      title: "Ash",
      tagline: "Direct and confident",
      gradient: [.indigo, .purple]
    ),
    VoiceOption(
      id: "ballad",
      title: "Ballad",
      tagline: "Smooth and expressive",
      gradient: [.purple, .pink]
    ),
    VoiceOption(
      id: "coral",
      title: "Coral",
      tagline: "Bright and friendly",
      gradient: [.orange, .pink]
    ),
    VoiceOption(
      id: "echo",
      title: "Echo",
      tagline: "Crisp and energetic",
      gradient: [.mint, .blue]
    ),
    VoiceOption(
      id: "sage",
      title: "Sage",
      tagline: "Soft and thoughtful",
      gradient: [.teal, .green]
    ),
    VoiceOption(
      id: "shimmer",
      title: "Shimmer",
      tagline: "Light and upbeat",
      gradient: [.yellow, .orange]
    ),
    VoiceOption(
      id: "verse",
      title: "Verse",
      tagline: "Versatile and animated",
      gradient: [.pink, .indigo]
    ),
  ]
}
