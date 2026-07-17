import Foundation
import GhosttySwift

enum AgentHubGhosttyAppearanceConfiguration {
  static func path(isDark: Bool) -> String? {
    Bundle.module.url(
      forResource: isDark ? "ghostty-dark" : "ghostty-light",
      withExtension: "conf"
    )?.path
  }

  static func colorScheme(isDark: Bool) -> GhosttyColorScheme {
    isDark ? .dark : .light
  }
}
