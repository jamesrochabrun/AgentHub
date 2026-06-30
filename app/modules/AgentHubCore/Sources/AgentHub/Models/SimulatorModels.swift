//
//  SimulatorModels.swift
//  AgentHub
//
//  Data models for iOS Simulator management.
//

import Foundation

// MARK: - SimulatorDevice

struct SimulatorDevice: Identifiable, Sendable, Hashable, Codable {
  let udid: String
  let name: String
  let state: String
  let isAvailable: Bool
  let deviceTypeIdentifier: String

  var id: String { udid }
  var isBooted: Bool { state == "Booted" }
}

// MARK: - SimulatorRuntime

struct SimulatorRuntime: Identifiable, Sendable {
  let identifier: String   // e.g. "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
  let displayName: String  // e.g. "iOS 17.5"
  var devices: [SimulatorDevice]

  var id: String { identifier }
  var availableDevices: [SimulatorDevice] { devices.filter { $0.isAvailable } }
}

// MARK: - PhysicalIOSDevice

/// A connected iOS/iPadOS hardware run destination reported by Xcode.
struct PhysicalIOSDevice: Identifiable, Sendable, Hashable, Codable {
  let identifier: String
  let name: String
  let modelName: String
  let operatingSystemVersion: String
  let interface: String?

  var id: String { identifier }

  var subtitle: String {
    let model = modelName.isEmpty || modelName == name ? nil : modelName
    let version = operatingSystemVersion.isEmpty ? nil : operatingSystemVersion
    return [model, version].compactMap { $0 }.joined(separator: " - ")
  }
}

// MARK: - SimulatorState

public enum SimulatorState: Equatable, Sendable {
  case idle
  case booting
  case building
  case installing
  case launching
  case booted
  case shuttingDown
  case failed(error: String)
}

// MARK: - XcodePlatform

/// Platform a given Xcode project supports.
public enum XcodePlatform: Sendable, Hashable {
  case iOS
  case macOS
}

// MARK: - MacRunState

/// State for macOS build-and-run action, keyed by projectPath.
public enum MacRunState: Equatable, Sendable {
  case idle
  case building
  case done
  case failed(error: String)
}
