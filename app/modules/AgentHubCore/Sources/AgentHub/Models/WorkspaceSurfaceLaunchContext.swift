//
//  WorkspaceSurfaceLaunchContext.swift
//  AgentHub
//

import Foundation

public struct WorkspaceSurfaceLaunchContext: Equatable, Sendable {
  public let provider: SessionProviderKind?
  public let projectPath: String
  public let startedAt: Date

  public init(provider: SessionProviderKind?, projectPath: String, startedAt: Date) {
    self.provider = provider
    self.projectPath = projectPath
    self.startedAt = startedAt
  }
}
