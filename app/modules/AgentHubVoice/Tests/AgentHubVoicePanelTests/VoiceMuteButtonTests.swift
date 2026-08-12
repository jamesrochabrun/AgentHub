import Testing
@testable import AgentHubVoicePanel

struct VoiceMuteButtonTests {
  @Test
  func liveWhenNothingSilencesTheMicrophone() {
    #expect(
      VoiceMuteButton.DisplayState.make(
        isMuted: false,
        isGated: false,
        isStandby: false
      ) == .live
    )
  }

  @Test
  func gateShowsAsPausedWhileAnnouncementIsInFlight() {
    #expect(
      VoiceMuteButton.DisplayState.make(
        isMuted: false,
        isGated: true,
        isStandby: false
      ) == .gated
    )
  }

  @Test
  func standbyShowsWhileAwaitingASessionCompletion() {
    #expect(
      VoiceMuteButton.DisplayState.make(
        isMuted: false,
        isGated: false,
        isStandby: true
      ) == .standby
    )
  }

  @Test
  func deliveryGateOutranksStandby() {
    #expect(
      VoiceMuteButton.DisplayState.make(
        isMuted: false,
        isGated: true,
        isStandby: true
      ) == .gated
    )
  }

  @Test
  func userMuteWinsOverEveryAutomaticPause() {
    #expect(
      VoiceMuteButton.DisplayState.make(
        isMuted: true,
        isGated: true,
        isStandby: true
      ) == .userMuted
    )
    #expect(
      VoiceMuteButton.DisplayState.make(
        isMuted: true,
        isGated: false,
        isStandby: false
      ) == .userMuted
    )
  }
}
