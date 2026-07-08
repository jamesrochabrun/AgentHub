//
//  SimulatorPreferencePersisting.swift
//  AgentHub
//
//  Persistence interface for per-project simulator run-destination preferences.
//

import Foundation

/// Persists the run destination a project/worktree last selected so the
/// simulator panel restores it across app relaunches.
public protocol SimulatorPreferencePersisting: Sendable {
  func getProjectSimulatorPreferences() async throws -> [ProjectSimulatorPreference]
  func setProjectSimulatorPreference(_ preference: ProjectSimulatorPreference) async throws
  func deleteProjectSimulatorPreference(projectPath: String) async throws
}

extension SessionMetadataStore: SimulatorPreferencePersisting {}
