//
//  TerminalWorkspaceSnapshot.swift
//  AgentHub
//
//  Persisted structure for restoring embedded terminal workspaces.
//

import AgentHubSessionGraph
import Foundation

public struct TerminalWorkspaceSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var panels: [TerminalWorkspacePanelSnapshot]
  public var activePanelIndex: Int
  public var splitLayout: TerminalWorkspaceSplitNode?
  public var splitRatiosByPath: [String: [Double]]

  public init(
    schemaVersion: Int = 4,
    panels: [TerminalWorkspacePanelSnapshot],
    activePanelIndex: Int = 0,
    splitLayout: TerminalWorkspaceSplitNode? = nil,
    splitRatiosByPath: [String: [Double]] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.panels = panels
    self.activePanelIndex = activePanelIndex
    self.splitLayout = splitLayout
    self.splitRatiosByPath = splitRatiosByPath
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case panels
    case activePanelIndex
    case splitLayout
    case splitRatiosByPath
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    panels = try container.decode([TerminalWorkspacePanelSnapshot].self, forKey: .panels)
    activePanelIndex = try container.decodeIfPresent(Int.self, forKey: .activePanelIndex) ?? 0
    splitLayout = try container.decodeIfPresent(TerminalWorkspaceSplitNode.self, forKey: .splitLayout)
    splitRatiosByPath = try container.decodeIfPresent(
      [String: [Double]].self,
      forKey: .splitRatiosByPath
    ) ?? [:]
  }

  public func normalizedSplitRatios() -> [String: [Double]] {
    guard let splitLayout else { return [:] }
    var childCounts: [String: Int] = [:]
    splitLayout.collectSplitChildCounts(path: "root", into: &childCounts)

    return Dictionary(uniqueKeysWithValues: childCounts.compactMap { path, childCount in
      guard let ratios = splitRatiosByPath[path] else { return nil }
      return (path, Self.normalized(ratios: ratios, childCount: childCount))
    })
  }

  private static func normalized(ratios: [Double], childCount: Int) -> [Double] {
    guard childCount > 0 else { return [] }
    guard ratios.count == childCount,
          ratios.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      return Array(repeating: 1 / Double(childCount), count: childCount)
    }
    let total = ratios.reduce(0, +)
    guard total > 0 else {
      return Array(repeating: 1 / Double(childCount), count: childCount)
    }
    return ratios.map { $0 / total }
  }
}

public enum TerminalWorkspaceSplitAxis: String, Codable, Equatable, Sendable {
  case horizontal
  case vertical
}

public indirect enum TerminalWorkspaceSplitNode: Equatable, Sendable {
  case panel(index: Int)
  case split(axis: TerminalWorkspaceSplitAxis, children: [TerminalWorkspaceSplitNode])

  public var panelIndexes: [Int] {
    switch self {
    case .panel(let index):
      return [index]
    case .split(_, let children):
      return children.flatMap(\.panelIndexes)
    }
  }

  public func remappingPanelIndexes(
    _ normalizedIndexByOriginalIndex: [Int: Int]
  ) -> TerminalWorkspaceSplitNode? {
    switch self {
    case .panel(let index):
      guard let normalizedIndex = normalizedIndexByOriginalIndex[index] else {
        return nil
      }
      return .panel(index: normalizedIndex)

    case .split(let axis, let children):
      let remappedChildren = children.compactMap {
        $0.remappingPanelIndexes(normalizedIndexByOriginalIndex)
      }
      guard !remappedChildren.isEmpty else { return nil }
      return .split(axis: axis, children: remappedChildren)
    }
  }

  fileprivate func collectSplitChildCounts(
    path: String,
    into result: inout [String: Int]
  ) {
    switch self {
    case .panel:
      return
    case .split(_, let children):
      result[path] = children.count
      for (index, child) in children.enumerated() {
        child.collectSplitChildCounts(path: "\(path).\(index)", into: &result)
      }
    }
  }
}

extension TerminalWorkspaceSplitNode: Codable {
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
        children: try container.decode([TerminalWorkspaceSplitNode].self, forKey: .children)
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
