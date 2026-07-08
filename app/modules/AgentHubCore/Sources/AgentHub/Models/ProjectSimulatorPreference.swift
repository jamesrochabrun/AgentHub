//
//  ProjectSimulatorPreference.swift
//  AgentHub
//
//  SQLite record for the run destination a project/worktree last selected
//  in the simulator preview panel.
//

import Foundation
import GRDB

public struct ProjectSimulatorPreference: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public enum Kind: String, Codable, Sendable {
    case simulator
    case physical
  }

  public var projectPath: String
  public var deviceIdentifier: String
  public var kind: Kind
  public var updatedAt: Date

  public static var databaseTableName: String { "project_simulator_preferences" }

  public init(
    projectPath: String,
    deviceIdentifier: String,
    kind: Kind,
    updatedAt: Date = Date.now
  ) {
    self.projectPath = projectPath
    self.deviceIdentifier = deviceIdentifier
    self.kind = kind
    self.updatedAt = updatedAt
  }
}
