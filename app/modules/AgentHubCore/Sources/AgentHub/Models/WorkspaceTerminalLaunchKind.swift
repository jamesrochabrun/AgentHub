//
//  WorkspaceTerminalLaunchKind.swift
//  AgentHub
//

public enum WorkspaceTerminalLaunchKind: Equatable, Sendable {
  case shell
  case agent(SessionProviderKind)
}
