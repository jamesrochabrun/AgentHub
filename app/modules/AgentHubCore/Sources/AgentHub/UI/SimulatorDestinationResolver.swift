//
//  SimulatorDestinationResolver.swift
//  AgentHub
//
//  Resolves which run destination the simulator panel targets for a
//  project/worktree. Deliberately has no global fallback: a project with no
//  explicit selection and no persisted preference resolves to nil so the
//  panel shows a picker instead of another project's simulator.
//

import Foundation

/// A run destination the simulator panel can target: a simulator device or
/// a connected physical iOS device.
enum SimulatorRunDestination: Identifiable, Hashable {
  case simulator(SimulatorDevice)
  case physical(PhysicalIOSDevice)

  static func simulatorID(udid: String) -> String {
    "simulator:\(udid)"
  }

  static func physicalID(identifier: String) -> String {
    "physical:\(identifier)"
  }

  var id: String {
    switch self {
    case .simulator(let device):
      return Self.simulatorID(udid: device.udid)
    case .physical(let device):
      return Self.physicalID(identifier: device.identifier)
    }
  }

  var name: String {
    switch self {
    case .simulator(let device):
      return device.name
    case .physical(let device):
      return device.name
    }
  }

  var simulatorUDID: String? {
    if case .simulator(let device) = self { return device.udid }
    return nil
  }
}

enum SimulatorDestinationResolver {

  /// Precedence: explicit in-panel selection → persisted preferred simulator
  /// → persisted preferred physical device → nil (show the picker).
  static func resolve(
    selectedDestinationID: String?,
    preferredSimulatorUDID: String?,
    preferredPhysicalDeviceID: String?,
    simulators: [SimulatorDevice],
    physicalDevices: [PhysicalIOSDevice]
  ) -> SimulatorRunDestination? {
    if let selectedDestinationID {
      let destinations = physicalDevices.map(SimulatorRunDestination.physical)
        + simulators.map(SimulatorRunDestination.simulator)
      if let destination = destinations.first(where: { $0.id == selectedDestinationID }) {
        return destination
      }
    }
    if let preferredSimulatorUDID,
       let device = simulators.first(where: { $0.udid == preferredSimulatorUDID }) {
      return .simulator(device)
    }
    if let preferredPhysicalDeviceID,
       let device = physicalDevices.first(where: { $0.identifier == preferredPhysicalDeviceID }) {
      return .physical(device)
    }
    return nil
  }
}
