import Foundation
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Runtime theme Ghostty background adoption")
struct RuntimeThemeGhosttyBackgroundTests {

  @Test("Adopts appearance-matched user backgrounds")
  func adoptsMatchedBackgrounds() throws {
    let theme = try ghosttyLikeTheme()
    let adopted = theme.applyingGhosttyUserBackground(
      GhosttyUserBackground(lightHex: "#eff1f5", darkHex: "#1e1e2e")
    )

    #expect(adopted.backgroundDark == Color(hex: "#1e1e2e"))
    #expect(adopted.backgroundLight == Color(hex: "#eff1f5"))
    #expect(adopted.hasCustomBackgrounds)
  }

  @Test("Keeps the theme backdrop when luminance mismatches the appearance")
  func rejectsMismatchedLuminance() throws {
    let theme = try ghosttyLikeTheme()
    // A dark color offered for light mode and a light color for dark mode
    // must both be rejected.
    let adopted = theme.applyingGhosttyUserBackground(
      GhosttyUserBackground(lightHex: "#1e1e2e", darkHex: "#eff1f5")
    )

    #expect(adopted.backgroundDark == theme.backgroundDark)
    #expect(adopted.backgroundLight == theme.backgroundLight)
  }

  @Test("No resolved background leaves the theme untouched")
  func noBackgroundIsUntouched() throws {
    let theme = try ghosttyLikeTheme()
    let adopted = theme.applyingGhosttyUserBackground(.none)

    #expect(adopted.backgroundDark == theme.backgroundDark)
    #expect(adopted.backgroundLight == theme.backgroundLight)
  }

  @Test("Partial resolution adopts only the matching side")
  func partialResolution() throws {
    let theme = try ghosttyLikeTheme()
    let adopted = theme.applyingGhosttyUserBackground(
      GhosttyUserBackground(lightHex: nil, darkHex: "#101015")
    )

    #expect(adopted.backgroundDark == Color(hex: "#101015"))
    #expect(adopted.backgroundLight == theme.backgroundLight)
  }

  private func ghosttyLikeTheme() throws -> RuntimeTheme {
    let yaml = """
      name: "Ghostty"
      version: "1.0"
      colors:
        brand:
          primary: "#A0AEC0"
          secondary: "#2D3748"
          tertiary: "#CBD5E0"
        backgrounds:
          dark: "#252627"
          light: "#FBFBFF"
      """
    let theme = try YAMLThemeParser().parse(data: Data(yaml.utf8))
    return RuntimeTheme(from: theme, sourceFileName: "ghostty.yaml")
  }
}
