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
  public var layout: TerminalWorkspaceLayoutNode?

  public init(
    schemaVersion: Int = 1,
    panels: [TerminalWorkspacePanelSnapshot],
    activePanelIndex: Int = 0,
    layout: TerminalWorkspaceLayoutNode? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.panels = panels
    self.activePanelIndex = activePanelIndex
    self.layout = layout
  }
}

public indirect enum TerminalWorkspaceLayoutNode: Codable, Equatable, Sendable {
  case panel(index: Int)
  case split(axis: TerminalWorkspaceSplitAxis, children: [TerminalWorkspaceLayoutNode])

  private enum CodingKeys: String, CodingKey {
    case type
    case index
    case axis
    case children
  }

  private enum NodeType: String, Codable {
    case panel
    case split
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(NodeType.self, forKey: .type)
    switch type {
    case .panel:
      self = .panel(index: try container.decode(Int.self, forKey: .index))
    case .split:
      self = .split(
        axis: try container.decode(TerminalWorkspaceSplitAxis.self, forKey: .axis),
        children: try container.decode([TerminalWorkspaceLayoutNode].self, forKey: .children)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .panel(let index):
      try container.encode(NodeType.panel, forKey: .type)
      try container.encode(index, forKey: .index)
    case .split(let axis, let children):
      try container.encode(NodeType.split, forKey: .type)
      try container.encode(axis, forKey: .axis)
      try container.encode(children, forKey: .children)
    }
  }
}

public enum TerminalWorkspaceSplitAxis: String, Codable, Equatable, Sendable {
  /// Places panes side-by-side with a vertical divider.
  case vertical
  /// Places panes above and below each other with a horizontal divider.
  case horizontal
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
