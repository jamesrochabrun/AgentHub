//
//  SimulatorDisplayMetrics.swift
//  AgentHub
//
//  Real display corner radii per simulator device type, in framebuffer pixels.
//  Values are UIKit's per-device `_displayCornerRadius` (points × scale) as
//  documented by community dumps — CoreSimulator's device profiles don't
//  expose the radius, only a chrome-artwork identifier. Unknown devices fall
//  back to `SimulatorDeviceChromeView`'s aspect-ratio heuristic.
//

import CoreGraphics
import Foundation

enum SimulatorDisplayMetrics {
  /// (display corner radius in points, screen scale) per CoreSimulator device
  /// type suffix (`com.apple.CoreSimulator.SimDeviceType.<suffix>`).
  private static let knownRadii: [String: (points: CGFloat, scale: CGFloat)] = [
    // 39 pt @3x
    "iPhone-X": (39, 3), "iPhone-XS": (39, 3), "iPhone-XS-Max": (39, 3),
    "iPhone-11-Pro": (39, 3), "iPhone-11-Pro-Max": (39, 3),
    // 41.5 pt @2x
    "iPhone-XR": (41.5, 2), "iPhone-11": (41.5, 2),
    // 44 pt @3x
    "iPhone-12-mini": (44, 3), "iPhone-13-mini": (44, 3),
    // 47.33 pt @3x
    "iPhone-12": (47.33, 3), "iPhone-12-Pro": (47.33, 3),
    "iPhone-13": (47.33, 3), "iPhone-13-Pro": (47.33, 3),
    "iPhone-14": (47.33, 3),
    // 53.33 pt @3x
    "iPhone-12-Pro-Max": (53.33, 3), "iPhone-13-Pro-Max": (53.33, 3),
    "iPhone-14-Plus": (53.33, 3),
    // 55 pt @3x
    "iPhone-14-Pro": (55, 3), "iPhone-14-Pro-Max": (55, 3),
    "iPhone-15": (55, 3), "iPhone-15-Plus": (55, 3),
    "iPhone-15-Pro": (55, 3), "iPhone-15-Pro-Max": (55, 3),
    "iPhone-16": (55, 3), "iPhone-16-Plus": (55, 3), "iPhone-16e": (55, 3),
    // 62 pt @3x
    "iPhone-16-Pro": (62, 3), "iPhone-16-Pro-Max": (62, 3),
    "iPhone-17": (62, 3), "iPhone-17-Pro": (62, 3),
    "iPhone-17-Pro-Max": (62, 3), "iPhone-Air": (62, 3),
    // Square screens
    "iPhone-SE-2nd-generation": (0, 2), "iPhone-SE-3rd-generation": (0, 2),
    "iPhone-8": (0, 2), "iPhone-8-Plus": (0, 3),

    // iPads (all @2x). Slightly less rigorously documented than iPhones.
    // 30 pt — M4/M5 Pro
    "iPad-Pro-11-inch-M4": (30, 2), "iPad-Pro-13-inch-M4": (30, 2),
    "iPad-Pro-11-inch-M5": (30, 2), "iPad-Pro-13-inch-M5": (30, 2),
    // 25 pt — iPad 10th gen / A16
    "iPad-10th-generation": (25, 2), "iPad-A16": (25, 2),
    // 21.5 pt — iPad mini 6 / A17 Pro
    "iPad-mini-6th-generation": (21.5, 2), "iPad-mini-A17-Pro": (21.5, 2),
    // 18 pt — pre-M4 Pros and Airs (4th gen onward)
    "iPad-Pro--11-inch-": (18, 2),
    "iPad-Pro--11-inch---2nd-generation-": (18, 2),
    "iPad-Pro-11-inch-3rd-generation": (18, 2),
    "iPad-Pro-11-inch-4th-generation": (18, 2),
    "iPad-Pro--12-9-inch---3rd-generation-": (18, 2),
    "iPad-Pro--12-9-inch---4th-generation-": (18, 2),
    "iPad-Pro-12-9-inch-5th-generation": (18, 2),
    "iPad-Pro-12-9-inch-6th-generation": (18, 2),
    "iPad-Air--4th-generation-": (18, 2), "iPad-Air-5th-generation": (18, 2),
    "iPad-Air-11-inch-M2": (18, 2), "iPad-Air-13-inch-M2": (18, 2),
    "iPad-Air-11-inch-M3": (18, 2), "iPad-Air-13-inch-M3": (18, 2),
    "iPad-Air-11-inch-M4": (18, 2), "iPad-Air-13-inch-M4": (18, 2),
    // Home-button iPads: square screens
    "iPad-Pro": (0, 2), "iPad-Pro--9-7-inch-": (0, 2),
    "iPad-Pro--10-5-inch-": (0, 2), "iPad-Pro--12-9-inch---2nd-generation-": (0, 2),
    "iPad--5th-generation-": (0, 2), "iPad--6th-generation-": (0, 2),
    "iPad--7th-generation-": (0, 2), "iPad--8th-generation-": (0, 2),
    "iPad-9th-generation": (0, 2), "iPad-Air-2": (0, 2),
    "iPad-Air--3rd-generation-": (0, 2), "iPad-mini-4": (0, 2),
    "iPad-mini--5th-generation-": (0, 2),
  ]

  /// The device's true display corner radius in framebuffer pixels, or nil
  /// when the device type isn't in the table.
  static func displayCornerRadiusPixels(deviceTypeIdentifier: String) -> CGFloat? {
    var suffix = deviceTypeIdentifier
      .replacingOccurrences(of: "com.apple.CoreSimulator.SimDeviceType.", with: "")
    // Memory variants share a device type (e.g. "iPad-Pro-13-inch-M5-16GB").
    suffix = suffix.replacingOccurrences(
      of: #"-\d+GB$"#, with: "", options: .regularExpression)
    guard let entry = knownRadii[suffix] else { return nil }
    return entry.points * entry.scale
  }
}
