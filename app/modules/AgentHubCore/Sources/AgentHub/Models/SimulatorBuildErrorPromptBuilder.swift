//
//  SimulatorBuildErrorPromptBuilder.swift
//  AgentHub
//
//  Builds the prompt sent to the active agent when a simulator build/run
//  failure needs to be handed back for repair.
//

import Foundation

enum SimulatorBuildErrorPromptBuilder {
  static func prompt(for error: String) -> String {
    "Fix this simulator build/run error:\n\(error)"
  }
}
