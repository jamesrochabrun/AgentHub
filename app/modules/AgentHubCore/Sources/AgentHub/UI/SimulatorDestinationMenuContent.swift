//
//  SimulatorDestinationMenuContent.swift
//  AgentHub
//
//  Shared menu rows for picking a simulator run destination — used by the
//  simulator panel's header picker and its "choose a destination" empty state.
//

import SwiftUI

struct SimulatorDestinationMenuContent: View {
  let physicalDevices: [PhysicalIOSDevice]
  let simulators: [SimulatorDevice]
  let activeDestinationID: String?
  let onSelectSimulator: (String) -> Void
  let onSelectPhysicalDevice: (String) -> Void

  var body: some View {
    if !physicalDevices.isEmpty {
      Section("Connected Devices") {
        ForEach(physicalDevices) { device in
          Button {
            onSelectPhysicalDevice(device.identifier)
          } label: {
            HStack {
              Text(device.name)
              Text(device.subtitle.isEmpty ? "Device" : device.subtitle)
              if activeDestinationID == SimulatorRunDestination.physical(device).id {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }
    }

    if !simulators.isEmpty {
      Section("Simulators") {
        ForEach(simulators) { device in
          Button {
            onSelectSimulator(device.udid)
          } label: {
            HStack {
              Text(device.name)
              if device.isBooted {
                Text("Running")
              }
              if activeDestinationID == SimulatorRunDestination.simulatorID(udid: device.udid) {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }
    }
  }
}
