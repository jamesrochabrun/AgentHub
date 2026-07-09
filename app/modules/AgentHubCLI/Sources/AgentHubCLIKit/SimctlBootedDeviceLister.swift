import Foundation

/// A simulator device as reported live by `simctl`, independent of any
/// AgentHub panel context. Lets the MCP server answer "what is actually
/// running right now" even when no panel has written a context file.
public struct SimctlDevice: Equatable, Sendable {
  public let udid: String
  public let name: String
  public let runtimeName: String
  public let isBooted: Bool

  public init(udid: String, name: String, runtimeName: String, isBooted: Bool) {
    self.udid = udid
    self.name = name
    self.runtimeName = runtimeName
    self.isBooted = isBooted
  }
}

public protocol SimctlDeviceListing: Sendable {
  /// All currently booted simulators, or an empty array when simctl is
  /// unavailable/fails — callers treat this as best-effort enrichment.
  func bootedDevices() -> [SimctlDevice]
}

public struct SimctlBootedDeviceLister: SimctlDeviceListing {
  public init() {}

  public func bootedDevices() -> [SimctlDevice] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "list", "devices", "booted", "--json"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return []
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }
    return Self.parseBootedDevices(from: data)
  }

  /// Parses `simctl list devices --json` output. Pure, so tests exercise it
  /// with canned payloads without shelling out.
  public static func parseBootedDevices(from data: Data) -> [SimctlDevice] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let runtimes = object["devices"] as? [String: Any]
    else {
      return []
    }

    var devices: [SimctlDevice] = []
    for (runtimeIdentifier, value) in runtimes {
      guard let entries = value as? [[String: Any]] else { continue }
      for entry in entries {
        guard let udid = entry["udid"] as? String,
              let name = entry["name"] as? String,
              (entry["state"] as? String) == "Booted"
        else { continue }
        devices.append(SimctlDevice(
          udid: udid,
          name: name,
          runtimeName: Self.displayName(forRuntimeIdentifier: runtimeIdentifier),
          isBooted: true
        ))
      }
    }
    return devices.sorted { $0.name == $1.name ? $0.udid < $1.udid : $0.name < $1.name }
  }

  /// "com.apple.CoreSimulator.SimRuntime.iOS-18-2" → "iOS 18.2".
  static func displayName(forRuntimeIdentifier identifier: String) -> String {
    guard let lastComponent = identifier.split(separator: ".").last else { return identifier }
    let parts = lastComponent.split(separator: "-", maxSplits: 1)
    guard parts.count == 2 else { return String(lastComponent) }
    return "\(parts[0]) \(parts[1].replacingOccurrences(of: "-", with: "."))"
  }
}
