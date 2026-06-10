import Testing

@testable import SimulatorPreview

@Suite("SimulatorStreamAvailability")
struct SimulatorStreamAvailabilityTests {
  private let dev = "/Applications/Xcode.app/Contents/Developer"

  @Test("both frameworks present → CoreSimulator backend, interactive")
  func bothPresent() {
    let a = SimulatorStreamAvailability.probe(developerDir: dev) { _ in true }
    #expect(a.backend == .coreSimulator)
    #expect(a.isInteractive)
    #expect(a.coreSimulatorFrameworkPath != nil)
    #expect(a.simulatorKitFrameworkPath != nil)
  }

  @Test("missing SimulatorKit → screenshot fallback, not interactive")
  func missingSimulatorKit() {
    let a = SimulatorStreamAvailability.probe(developerDir: dev) { path in
      !path.contains("SimulatorKit")
    }
    #expect(a.backend == .screenshotPolling)
    #expect(!a.isInteractive)
    #expect(a.simulatorKitFrameworkPath == nil)
  }

  @Test("missing CoreSimulator → screenshot fallback")
  func missingCoreSimulator() {
    let a = SimulatorStreamAvailability.probe(developerDir: dev) { path in
      !path.contains("CoreSimulator")
    }
    #expect(a.backend == .screenshotPolling)
    #expect(a.coreSimulatorFrameworkPath == nil)
  }

  @Test("nothing present → screenshot fallback")
  func nothingPresent() {
    let a = SimulatorStreamAvailability.probe(developerDir: dev) { _ in false }
    #expect(a.backend == .screenshotPolling)
    #expect(!a.isInteractive)
  }
}
