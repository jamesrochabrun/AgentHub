import Testing

@testable import AgentHubCore

@Suite("AppVisibilityMonitor")
@MainActor
struct AppVisibilityMonitorTests {

  @Test("Defaults to visible when not observing the application")
  func defaultsToVisibleWithoutObservation() {
    let monitor = AppVisibilityMonitor(observesApplication: false)
    #expect(monitor.isVisible)
  }

  @Test("Honors a seeded visibility value")
  func honorsSeededValue() {
    let monitor = AppVisibilityMonitor(isVisible: false, observesApplication: false)
    #expect(!monitor.isVisible)
  }

  @Test("setVisible flips state")
  func setVisibleFlipsState() {
    let monitor = AppVisibilityMonitor(observesApplication: false)

    monitor.setVisible(false)
    #expect(!monitor.isVisible)

    monitor.setVisible(true)
    #expect(monitor.isVisible)
  }

  @Test("Redundant setVisible calls are no-ops")
  func redundantSetVisibleIsNoOp() {
    let monitor = AppVisibilityMonitor(isVisible: true, observesApplication: false)

    monitor.setVisible(true)
    #expect(monitor.isVisible)

    monitor.setVisible(false)
    monitor.setVisible(false)
    #expect(!monitor.isVisible)
  }
}

@Suite("StatusPulsePolicy")
struct StatusPulsePolicyTests {

  @Test("Pulses only when the session is active and the app is visible")
  func pulsesOnlyWhenActiveAndVisible() {
    #expect(StatusPulsePolicy.shouldPulse(isActiveStatus: true, isAppVisible: true))
    #expect(!StatusPulsePolicy.shouldPulse(isActiveStatus: true, isAppVisible: false))
    #expect(!StatusPulsePolicy.shouldPulse(isActiveStatus: false, isAppVisible: true))
    #expect(!StatusPulsePolicy.shouldPulse(isActiveStatus: false, isAppVisible: false))
  }

  @Test("An occluded app never pulses, whatever the session status")
  func occludedAppNeverPulses() {
    for isActive in [true, false] {
      #expect(!StatusPulsePolicy.shouldPulse(isActiveStatus: isActive, isAppVisible: false))
    }
  }
}
