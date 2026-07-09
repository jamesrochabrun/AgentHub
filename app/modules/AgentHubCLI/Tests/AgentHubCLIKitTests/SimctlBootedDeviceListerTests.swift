import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("SimctlBootedDeviceLister")
struct SimctlBootedDeviceListerTests {
  @Test("Parses booted devices across runtimes and skips non-booted entries")
  func parsesBootedDevices() throws {
    let payload = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
          { "udid": "UDID-A", "name": "iPhone 16 Pro", "state": "Booted" },
          { "udid": "UDID-B", "name": "iPhone 16", "state": "Shutdown" }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
          { "udid": "UDID-C", "name": "iPhone 17 Pro", "state": "Booted" }
        ]
      }
    }
    """

    let devices = SimctlBootedDeviceLister.parseBootedDevices(from: Data(payload.utf8))

    #expect(devices == [
      SimctlDevice(udid: "UDID-A", name: "iPhone 16 Pro", runtimeName: "iOS 18.2", isBooted: true),
      SimctlDevice(udid: "UDID-C", name: "iPhone 17 Pro", runtimeName: "iOS 26.0", isBooted: true),
    ])
  }

  @Test("Malformed payloads parse to an empty list")
  func malformedPayloadParsesEmpty() {
    #expect(SimctlBootedDeviceLister.parseBootedDevices(from: Data("not json".utf8)).isEmpty)
    #expect(SimctlBootedDeviceLister.parseBootedDevices(from: Data("{}".utf8)).isEmpty)
  }

  @Test("Runtime identifiers map to display names")
  func runtimeDisplayNames() {
    #expect(
      SimctlBootedDeviceLister.displayName(
        forRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
      ) == "iOS 18.2"
    )
    #expect(
      SimctlBootedDeviceLister.displayName(forRuntimeIdentifier: "weird") == "weird"
    )
  }
}
