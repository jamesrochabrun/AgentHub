import AgentHubVoice
import Foundation
import Testing
@testable import AgentHubVoicePanel

struct LiquidOrbActivityTests {
  @Test
  func intensityRisesFromIdleToListeningToSpeaking() {
    let disconnected = LiquidOrbActivity.resolve(
      state: .disconnected,
      isAssistantSpeaking: false,
      microphoneLevel: 0,
      assistantLevel: 0
    )
    let idle = LiquidOrbActivity.resolve(
      state: .idle,
      isAssistantSpeaking: false,
      microphoneLevel: 0,
      assistantLevel: 0
    )
    let listening = LiquidOrbActivity.resolve(
      state: .userSpeaking,
      isAssistantSpeaking: false,
      microphoneLevel: 0.5,
      assistantLevel: 0
    )
    let speaking = LiquidOrbActivity.resolve(
      state: .speaking,
      isAssistantSpeaking: false,
      microphoneLevel: 0,
      assistantLevel: 0.5
    )

    #expect(disconnected.intensity < idle.intensity)
    #expect(idle.intensity < listening.intensity)
    #expect(listening.intensity < speaking.intensity)
    #expect(disconnected.speed < idle.speed)
    #expect(idle.speed < speaking.speed)
  }

  @Test
  func microphoneLevelBoostsListeningIntensity() {
    let quiet = LiquidOrbActivity.resolve(
      state: .userSpeaking,
      isAssistantSpeaking: false,
      microphoneLevel: 0,
      assistantLevel: 0
    )
    let loud = LiquidOrbActivity.resolve(
      state: .userSpeaking,
      isAssistantSpeaking: false,
      microphoneLevel: 1,
      assistantLevel: 0
    )

    #expect(loud.intensity > quiet.intensity)
    #expect(loud.intensity <= 1)
  }

  @Test
  func assistantSpeakingFlagOverridesLaggingState() {
    let playback = LiquidOrbActivity.resolve(
      state: .idle,
      isAssistantSpeaking: true,
      microphoneLevel: 0,
      assistantLevel: 1
    )
    let spoken = LiquidOrbActivity.resolve(
      state: .speaking,
      isAssistantSpeaking: false,
      microphoneLevel: 0,
      assistantLevel: 1
    )

    #expect(playback == spoken)
    #expect(playback.intensity <= 1)
  }

  @Test
  func failedMatchesDisconnected() {
    let failed = LiquidOrbActivity.resolve(
      state: .failed("boom"),
      isAssistantSpeaking: false,
      microphoneLevel: 0,
      assistantLevel: 0
    )
    let disconnected = LiquidOrbActivity.resolve(
      state: .disconnected,
      isAssistantSpeaking: false,
      microphoneLevel: 0,
      assistantLevel: 0
    )

    #expect(failed == disconnected)
  }
}

struct LiquidOrbClockTests {
  @Test
  func phaseAdvancesContinuouslyAndConvergesToTarget() {
    let clock = LiquidOrbClock()
    let target = LiquidOrbActivity(intensity: 0.8, speed: 1.0)
    var date = Date(timeIntervalSinceReferenceDate: 0)

    var previousPhase = clock.advance(to: date, target: target).time
    var lastIntensity = 0.0
    for _ in 0..<300 {
      date = date.addingTimeInterval(1.0 / 60.0)
      let sample = clock.advance(to: date, target: target)
      #expect(sample.time >= previousPhase)
      previousPhase = sample.time
      lastIntensity = sample.intensity
    }

    #expect(abs(lastIntensity - target.intensity) < 0.01)
    #expect(abs(clock.smoothedSpeed - target.speed) < 0.01)
  }

  @Test
  func frameGapsAreClampedInsteadOfFastForwarding() {
    let clock = LiquidOrbClock()
    let target = LiquidOrbActivity(intensity: 1.0, speed: 1.0)
    let start = Date(timeIntervalSinceReferenceDate: 0)
    _ = clock.advance(to: start, target: target)
    let beforeGap = clock.phase

    // A 10-second stall (hidden window, debugger) must advance at most one
    // clamped frame, not ten seconds of phase.
    let afterGap = clock.advance(
      to: start.addingTimeInterval(10),
      target: target
    ).time

    #expect(afterGap - beforeGap <= (1.0 / 15.0) * target.speed + 0.0001)
  }

  @Test
  func speedChangeGlidesWithoutPhaseJump() {
    let clock = LiquidOrbClock()
    var date = Date(timeIntervalSinceReferenceDate: 0)
    let slow = LiquidOrbActivity(intensity: 0.4, speed: 0.5)
    let fast = LiquidOrbActivity(intensity: 0.9, speed: 1.7)

    _ = clock.advance(to: date, target: slow)
    for _ in 0..<60 {
      date = date.addingTimeInterval(1.0 / 60.0)
      _ = clock.advance(to: date, target: slow)
    }

    // Switching targets must never move phase faster than the max speed in a
    // single frame — continuity is the whole point of the clock.
    var previous = clock.phase
    for _ in 0..<120 {
      date = date.addingTimeInterval(1.0 / 60.0)
      let sample = clock.advance(to: date, target: fast)
      #expect(sample.time - previous <= (1.0 / 60.0) * fast.speed + 0.0001)
      previous = sample.time
    }
    #expect(abs(clock.smoothedSpeed - fast.speed) < 0.01)
  }
}
