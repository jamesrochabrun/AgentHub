//
//  ManagedProcessRecord.swift
//  AgentHub
//
//  SQLite record for app-spawned processes that may need crash recovery cleanup.
//

import Foundation
import GRDB

public enum ManagedProcessKind: String, Codable, CaseIterable, Sendable {
  case agentTerminal
  case auxiliaryShell
  case devServer

  var isTerminalProcess: Bool {
    switch self {
    case .agentTerminal, .auxiliaryShell:
      true
    case .devServer:
      false
    }
  }
}

public struct ManagedProcessRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public var pid: Int32
  public var processGroupId: Int32?
  public var processStartTimeSeconds: Int64?
  public var kind: String
  public var provider: String?
  public var terminalKey: String?
  public var sessionId: String?
  public var projectPath: String?
  public var expectedExecutable: String?
  public var registeredAt: Date
  public var updatedAt: Date

  public static var databaseTableName: String { "managed_processes" }

  public init(
    pid: Int32,
    processGroupId: Int32?,
    processStartTimeSeconds: Int64?,
    kind: ManagedProcessKind,
    provider: String?,
    terminalKey: String?,
    sessionId: String?,
    projectPath: String?,
    expectedExecutable: String?,
    registeredAt: Date = Date.now,
    updatedAt: Date = Date.now
  ) {
    self.pid = pid
    self.processGroupId = processGroupId
    self.processStartTimeSeconds = processStartTimeSeconds
    self.kind = kind.rawValue
    self.provider = provider
    self.terminalKey = terminalKey
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.expectedExecutable = expectedExecutable
    self.registeredAt = registeredAt
    self.updatedAt = updatedAt
  }

  public var processKind: ManagedProcessKind? {
    ManagedProcessKind(rawValue: kind)
  }
}
