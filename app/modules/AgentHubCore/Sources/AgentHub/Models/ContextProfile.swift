//
//  ContextProfile.swift
//  AgentHub
//
//  A named, reusable context selection. Project-scoped profiles belong to one
//  repository; personal profiles live at the user level and resolve their
//  project-relative paths against whichever project they are applied to
//  (missing paths are tolerated and reported, never fatal).
//

import Foundation

public enum ContextProfileScope: String, Codable, Sendable {
  case personal
  case project
}

public struct ContextProfile: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var scope: ContextProfileScope
  /// Normalized repository root the profile belongs to; empty for personal profiles.
  public var projectPath: String
  public var selection: ContextSelection
  public var isDefault: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String = UUID().uuidString,
    name: String,
    scope: ContextProfileScope,
    projectPath: String,
    selection: ContextSelection,
    isDefault: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.scope = scope
    self.projectPath = scope == .personal ? "" : projectPath
    self.selection = selection
    self.isDefault = isDefault
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
