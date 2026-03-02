import Testing
@testable import AgentHubCore

// MARK: - SimulatorDevice

@Suite("SimulatorDevice")
struct SimulatorDeviceTests {

  @Test func isBootedTrueWhenStateEqualsBooted() {
    let device = SimulatorDevice(
      udid: "ABCD-1234",
      name: "iPhone 15",
      state: "Booted",
      isAvailable: true,
      deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15"
    )
    #expect(device.isBooted == true)
  }

  @Test func isBootedFalseForShutdownState() {
    let device = SimulatorDevice(
      udid: "ABCD-1234",
      name: "iPhone 15",
      state: "Shutdown",
      isAvailable: true,
      deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15"
    )
    #expect(device.isBooted == false)
  }

  @Test func idEqualsUdid() {
    let udid = "EFGH-5678"
    let device = SimulatorDevice(
      udid: udid,
      name: "iPhone 14",
      state: "Shutdown",
      isAvailable: true,
      deviceTypeIdentifier: ""
    )
    #expect(device.id == udid)
  }
}

// MARK: - SimulatorRuntime

@Suite("SimulatorRuntime")
struct SimulatorRuntimeTests {

  @Test func availableDevicesFiltersUnavailableOnes() {
    let available = SimulatorDevice(
      udid: "A1",
      name: "iPhone 15",
      state: "Shutdown",
      isAvailable: true,
      deviceTypeIdentifier: ""
    )
    let unavailable = SimulatorDevice(
      udid: "A2",
      name: "iPhone 12",
      state: "Shutdown",
      isAvailable: false,
      deviceTypeIdentifier: ""
    )
    let runtime = SimulatorRuntime(
      identifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5",
      displayName: "iOS 17.5",
      devices: [available, unavailable]
    )
    #expect(runtime.availableDevices.count == 1)
    #expect(runtime.availableDevices.first?.udid == "A1")
  }

  @Test func availableDevicesEmptyWhenAllUnavailable() {
    let device = SimulatorDevice(
      udid: "X1",
      name: "iPhone 8",
      state: "Shutdown",
      isAvailable: false,
      deviceTypeIdentifier: ""
    )
    let runtime = SimulatorRuntime(
      identifier: "com.apple.CoreSimulator.SimRuntime.iOS-16-0",
      displayName: "iOS 16.0",
      devices: [device]
    )
    #expect(runtime.availableDevices.isEmpty)
  }

  @Test func idEqualsIdentifier() {
    let identifier = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    let runtime = SimulatorRuntime(identifier: identifier, displayName: "iOS 17.5", devices: [])
    #expect(runtime.id == identifier)
  }
}

// MARK: - SimulatorState

@Suite("SimulatorState")
struct SimulatorStateTests {

  @Test func equalityForSimpleCases() {
    #expect(SimulatorState.idle == .idle)
    #expect(SimulatorState.booting == .booting)
    #expect(SimulatorState.building == .building)
    #expect(SimulatorState.booted == .booted)
    #expect(SimulatorState.shuttingDown == .shuttingDown)
    #expect(SimulatorState.booted != .idle)
    #expect(SimulatorState.booting != .booted)
  }

  @Test func failedEqualityMatchesErrorString() {
    #expect(SimulatorState.failed(error: "oops") == .failed(error: "oops"))
  }

  @Test func failedInequalityOnDifferentErrors() {
    #expect(SimulatorState.failed(error: "x") != .failed(error: "y"))
  }
}

// MARK: - MacRunState

@Suite("MacRunState")
struct MacRunStateTests {

  @Test func equalityForAllCases() {
    #expect(MacRunState.idle == .idle)
    #expect(MacRunState.building == .building)
    #expect(MacRunState.done == .done)
    #expect(MacRunState.idle != .building)
    #expect(MacRunState.done != .idle)
  }

  @Test func failedAssociatedValueIsCompared() {
    #expect(MacRunState.failed(error: "err") == .failed(error: "err"))
    #expect(MacRunState.failed(error: "a") != .failed(error: "b"))
  }
}

// MARK: - XcodePlatform

@Suite("XcodePlatform")
struct XcodePlatformTests {

  @Test func hashableInSet() {
    var set: Set<XcodePlatform> = []
    set.insert(.iOS)
    set.insert(.iOS)
    #expect(set.count == 1)
  }

  @Test func setWithBothPlatforms() {
    let set: Set<XcodePlatform> = [.iOS, .macOS]
    #expect(set.count == 2)
    #expect(set.contains(.iOS))
    #expect(set.contains(.macOS))
  }
}
