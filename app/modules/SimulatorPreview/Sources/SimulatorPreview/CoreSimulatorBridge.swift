import Foundation
import ObjectiveC

// Portions of this file and its capture/HID siblings are adapted from
// EvanBacon/serve-sim (Apache License 2.0). See README.md for attribution.

/// Thin wrapper over the private CoreSimulator/SimulatorKit ObjC runtime used
/// to locate a booted `SimDevice` by UDID. All access is reflective
/// (`NSClassFromString` / `NSSelectorFromString`) so a missing framework or a
/// renamed selector degrades to `nil` rather than crashing.
enum CoreSimulatorBridge {
  /// dlopen both frameworks. Returns true only if CoreSimulator loaded.
  @discardableResult
  static func loadFrameworks(developerDir: String) -> Bool {
    let coreSim = dlopen(SimulatorStreamAvailability.coreSimulatorBinaryPath, RTLD_NOW)
    let simKitPath = developerDir
      + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
    _ = dlopen(simKitPath, RTLD_NOW)
    return coreSim != nil
  }

  /// Find a `SimDevice` (as `NSObject`) for the given UDID, or nil.
  static func findSimDevice(udid: String, developerDir: String) -> NSObject? {
    guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else {
      return nil
    }
    let sharedSel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
    guard contextClass.responds(to: sharedSel) else { return nil }
    guard let context = contextClass.perform(sharedSel, with: developerDir, with: nil)?
      .takeUnretainedValue() as? NSObject else { return nil }

    let deviceSetSel = NSSelectorFromString("defaultDeviceSetWithError:")
    guard let deviceSet = context.perform(deviceSetSel, with: nil)?
      .takeUnretainedValue() as? NSObject else { return nil }

    guard let devices = deviceSet.value(forKey: "devices") as? [NSObject] else { return nil }
    return devices.first {
      ($0.value(forKey: "UDID") as? NSUUID)?.uuidString.caseInsensitiveCompare(udid) == .orderedSame
    }
  }

  /// Reads the device's `stateString` ("Booted", "Shutdown", ...).
  static func stateString(of device: NSObject) -> String {
    (device.value(forKey: "stateString") as? String) ?? "unknown"
  }
}
