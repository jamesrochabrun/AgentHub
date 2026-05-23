//
//  TerminalWorkspaceSnapshot.swift
//  AgentHub
//
//  Persisted structure for restoring embedded terminal workspaces.
//

import Foundation

public struct TerminalWorkspaceSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var panels: [TerminalWorkspacePanelSnapshot]
  public var activePanelIndex: Int

  public init(
    schemaVersion: Int = 2,
    panels: [TerminalWorkspacePanelSnapshot],
    activePanelIndex: Int = 0
  ) {
    self.schemaVersion = schemaVersion
    self.panels = panels
    self.activePanelIndex = activePanelIndex
  }
}

public struct TerminalWorkspaceLinkedSessionSnapshot: Codable, Equatable, Sendable {
  public var provider: SessionProviderKind
  public var sessionId: String
  public var relationshipKind: SessionRelationshipKind

  public init(
    provider: SessionProviderKind,
    sessionId: String,
    relationshipKind: SessionRelationshipKind = .accessoryChild
  ) {
    self.provider = provider
    self.sessionId = sessionId
    self.relationshipKind = relationshipKind
  }
}

public struct TerminalWorkspacePanelSnapshot: Codable, Equatable, Sendable {
  public var role: TerminalWorkspacePanelRole
  public var tabs: [TerminalWorkspaceTabSnapshot]
  public var activeTabIndex: Int

  public init(
    role: TerminalWorkspacePanelRole,
    tabs: [TerminalWorkspaceTabSnapshot],
    activeTabIndex: Int = 0
  ) {
    self.role = role
    self.tabs = tabs
    self.activeTabIndex = activeTabIndex
  }
}

public enum TerminalWorkspacePanelRole: String, Codable, Equatable, Sendable {
  case primary
  case auxiliary
}

public struct TerminalWorkspaceTabSnapshot: Codable, Equatable, Sendable {
  public var role: TerminalWorkspaceTabRole
  public var name: String?
  public var title: String?
  public var workingDirectory: String?
  public var linkedSession: TerminalWorkspaceLinkedSessionSnapshot?

  public init(
    role: TerminalWorkspaceTabRole,
    name: String? = nil,
    title: String? = nil,
    workingDirectory: String? = nil,
    linkedSession: TerminalWorkspaceLinkedSessionSnapshot? = nil
  ) {
    self.role = role
    self.name = name
    self.title = title
    self.workingDirectory = workingDirectory
    self.linkedSession = linkedSession
  }
}

public enum TerminalWorkspaceTabRole: String, Codable, Equatable, Sendable {
  case agent
  case shell
}
