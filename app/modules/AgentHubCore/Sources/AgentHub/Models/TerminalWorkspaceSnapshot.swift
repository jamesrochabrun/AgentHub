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
    schemaVersion: Int = 1,
    panels: [TerminalWorkspacePanelSnapshot],
    activePanelIndex: Int = 0
  ) {
    self.schemaVersion = schemaVersion
    self.panels = panels
    self.activePanelIndex = activePanelIndex
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

  public init(
    role: TerminalWorkspaceTabRole,
    name: String? = nil,
    title: String? = nil,
    workingDirectory: String? = nil
  ) {
    self.role = role
    self.name = name
    self.title = title
    self.workingDirectory = workingDirectory
  }
}

public enum TerminalWorkspaceTabRole: String, Codable, Equatable, Sendable {
  case agent
  case shell
}
