import Foundation

/// Ephemeral UserDefaults suite for tests. Call `cleanUp()` (in a `defer`)
/// so the suite's plist does not accumulate under ~/Library/Preferences.
struct GhosttyTestDefaults {
  let defaults: UserDefaults
  let suiteName: String

  init() {
    suiteName = "com.agenthub.tests.ghostty-config.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}
