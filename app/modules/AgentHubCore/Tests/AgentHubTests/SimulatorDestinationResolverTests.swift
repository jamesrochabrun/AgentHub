import Foundation
import Testing

@testable import AgentHubCore

@Suite("SimulatorDestinationResolver")
struct SimulatorDestinationResolverTests {

  private func simulator(udid: String, booted: Bool = false) -> SimulatorDevice {
    SimulatorDevice(
      udid: udid,
      name: "iPhone \(udid)",
      state: booted ? "Booted" : "Shutdown",
      isAvailable: true,
      deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15"
    )
  }

  private func physical(identifier: String) -> PhysicalIOSDevice {
    PhysicalIOSDevice(
      identifier: identifier,
      name: "Phone \(identifier)",
      modelName: "iPhone 15",
      operatingSystemVersion: "18.0",
      interface: "usb"
    )
  }

  @Test("Explicit selection wins over preferences")
  func explicitSelectionWins() {
    let devices = [simulator(udid: "A"), simulator(udid: "B")]
    let result = SimulatorDestinationResolver.resolve(
      selectedDestinationID: SimulatorRunDestination.simulatorID(udid: "B"),
      preferredSimulatorUDID: "A",
      preferredPhysicalDeviceID: nil,
      simulators: devices,
      physicalDevices: []
    )
    #expect(result?.simulatorUDID == "B")
  }

  @Test("Persisted simulator preference resolves")
  func preferredSimulatorResolves() {
    let result = SimulatorDestinationResolver.resolve(
      selectedDestinationID: nil,
      preferredSimulatorUDID: "A",
      preferredPhysicalDeviceID: nil,
      simulators: [simulator(udid: "A")],
      physicalDevices: [physical(identifier: "P1")]
    )
    #expect(result?.simulatorUDID == "A")
  }

  @Test("Persisted physical preference resolves")
  func preferredPhysicalResolves() {
    let result = SimulatorDestinationResolver.resolve(
      selectedDestinationID: nil,
      preferredSimulatorUDID: nil,
      preferredPhysicalDeviceID: "P1",
      simulators: [simulator(udid: "A")],
      physicalDevices: [physical(identifier: "P1")]
    )
    #expect(result?.id == SimulatorRunDestination.physicalID(identifier: "P1"))
  }

  @Test("No association resolves to nil even with booted simulators and connected hardware")
  func noAssociationNeverAdoptsGlobalState() {
    let result = SimulatorDestinationResolver.resolve(
      selectedDestinationID: nil,
      preferredSimulatorUDID: nil,
      preferredPhysicalDeviceID: nil,
      simulators: [simulator(udid: "OTHER-PROJECT", booted: true)],
      physicalDevices: [physical(identifier: "P1")]
    )
    #expect(result == nil)
  }

  @Test("Stale preference for a device no longer in the list resolves to nil")
  func stalePreferenceResolvesToNil() {
    let result = SimulatorDestinationResolver.resolve(
      selectedDestinationID: nil,
      preferredSimulatorUDID: "GONE",
      preferredPhysicalDeviceID: "GONE-TOO",
      simulators: [simulator(udid: "A", booted: true)],
      physicalDevices: []
    )
    #expect(result == nil)
  }

  @Test("Stale explicit selection falls back to persisted preference")
  func staleSelectionFallsBackToPreference() {
    let result = SimulatorDestinationResolver.resolve(
      selectedDestinationID: SimulatorRunDestination.simulatorID(udid: "GONE"),
      preferredSimulatorUDID: "A",
      preferredPhysicalDeviceID: nil,
      simulators: [simulator(udid: "A")],
      physicalDevices: []
    )
    #expect(result?.simulatorUDID == "A")
  }

  @Test("No devices resolves to nil")
  func noDevicesResolvesToNil() {
    let result = SimulatorDestinationResolver.resolve(
      selectedDestinationID: nil,
      preferredSimulatorUDID: "A",
      preferredPhysicalDeviceID: nil,
      simulators: [],
      physicalDevices: []
    )
    #expect(result == nil)
  }
}
