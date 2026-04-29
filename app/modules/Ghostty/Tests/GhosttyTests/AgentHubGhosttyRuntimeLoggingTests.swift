import Testing
@testable import Ghostty

@Suite("AgentHub Ghostty runtime logging")
struct AgentHubGhosttyRuntimeLoggingTests {
  @Test("Quiet default disables Ghostty runtime logging when unset")
  func appliesQuietDefaultWhenUnset() {
    var recorded: (key: String, value: String, overwrite: Int32)?

    AgentHubGhosttyRuntimeLogging.applyQuietDefault(environment: [:]) { key, value, overwrite in
      recorded = (key, value, overwrite)
      return 0
    }

    #expect(recorded?.key == "GHOSTTY_LOG")
    #expect(recorded?.value == "false")
    #expect(recorded?.overwrite == 0)
  }

  @Test("Explicit Ghostty runtime logging configuration is preserved")
  func preservesExplicitLoggingConfiguration() {
    var didSetEnvironment = false

    AgentHubGhosttyRuntimeLogging.applyQuietDefault(
      environment: ["GHOSTTY_LOG": "stderr,macos"]
    ) { _, _, _ in
      didSetEnvironment = true
      return 0
    }

    #expect(didSetEnvironment == false)
  }
}
