//
//  SessionProviderKind.swift
//  AgentHubSessionGraph
//
//  Provider identity shared by session graph and AgentHubCore.
//

import Foundation

public enum SessionProviderKind: String, CaseIterable, Codable, Sendable {
  case claude = "Claude"
  case codex = "Codex"
}
