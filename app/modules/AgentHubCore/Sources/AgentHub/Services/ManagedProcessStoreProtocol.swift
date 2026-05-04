//
//  ManagedProcessStoreProtocol.swift
//  AgentHub
//
//  Persistence API for app-spawned process cleanup state.
//

import Foundation

public protocol ManagedProcessStoreProtocol: Sendable {
  func saveManagedProcess(_ record: ManagedProcessRecord) async throws
  func deleteManagedProcess(pid: Int32) async throws
  func deleteManagedProcesses(pids: [Int32]) async throws
  func getManagedProcesses() async throws -> [ManagedProcessRecord]
}
