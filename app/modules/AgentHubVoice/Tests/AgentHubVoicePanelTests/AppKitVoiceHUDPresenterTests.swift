import Testing
@testable import AgentHubVoicePanel

@MainActor
struct AppKitVoiceHUDPresenterTests {
  @Test(
    "Creates and presents the nonactivating voice HUD",
    .disabled(
      "headless-quarantine: NSPanel presentation requires a window server; see TestQuarantine.md"
    )
  )
  func presentsHUD() {}
}
