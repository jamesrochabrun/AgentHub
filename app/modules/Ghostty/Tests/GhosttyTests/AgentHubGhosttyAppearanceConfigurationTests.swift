import Foundation
import GhosttySwift
import Testing
@testable import Ghostty

@Suite("AgentHub Ghostty appearance configuration")
struct AgentHubGhosttyAppearanceConfigurationTests {
  @Test("Light appearance uses a high-contrast foreground and ANSI white")
  func lightAppearanceUsesReadableColors() throws {
    let path = try #require(
      AgentHubGhosttyAppearanceConfiguration.path(isDark: false)
    )
    let contents = try String(contentsOfFile: path, encoding: .utf8)

    #expect(contents.contains("background = #FBFBFF"))
    #expect(contents.contains("foreground = #2D3748"))
    #expect(contents.contains("palette = 15=#2D3748"))
    // minimum-contrast must never be set in the light profile: with
    // background-opacity 0, Ghostty computes contrast against transparent
    // black and flips dark text to white, making light mode illegible.
    let activeLines = contents
      .split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    #expect(!activeLines.contains { $0.contains("minimum-contrast") })
    #expect(contents.contains("background-opacity = 0"))
  }

  @Test("Dark appearance preserves the Ghostty palette")
  func darkAppearanceUsesGhosttyColors() throws {
    let path = try #require(
      AgentHubGhosttyAppearanceConfiguration.path(isDark: true)
    )
    let contents = try String(contentsOfFile: path, encoding: .utf8)

    #expect(contents.contains("background = #252627"))
    #expect(contents.contains("foreground = #E2E8F0"))
    #expect(contents.contains("palette = 15=#F7FAFC"))
    #expect(contents.contains("minimum-contrast = 4.5"))
  }

  @Test("System appearance maps to Ghostty's native color scheme")
  func appearanceMapsToNativeColorScheme() {
    #expect(AgentHubGhosttyAppearanceConfiguration.colorScheme(isDark: false) == .light)
    #expect(AgentHubGhosttyAppearanceConfiguration.colorScheme(isDark: true) == .dark)
  }
}
