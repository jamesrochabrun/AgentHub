import AppKit
import Testing

@testable import Ghostty

@Suite("AgentHub Ghostty terminal tab chrome")
struct AgentHubGhosttyTerminalTabChromeTests {

  @Test("Dark themed chrome derives darker surfaces from the theme background")
  func darkThemedChromeUsesDarkerBackgrounds() {
    let style = AgentHubGhosttyTerminalTabChrome.style(
      baseBackground: NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 46 / 255, alpha: 1),
      isDark: true
    )

    #expect(AgentHubGhosttyTerminalTabChrome.hexString(from: style.stripBackground) == "#191926")
    #expect(AgentHubGhosttyTerminalTabChrome.hexString(from: style.activeBackground) == "#161621")
  }

  @Test("No matched theme background keeps the system chrome style")
  func missingThemeBackgroundUsesSystemStyle() {
    #expect(
      AgentHubGhosttyTerminalTabChrome.style(isDark: true, theme: nil)
        == AgentHubGhosttyTerminalTabChrome.systemStyle
    )
  }
}
