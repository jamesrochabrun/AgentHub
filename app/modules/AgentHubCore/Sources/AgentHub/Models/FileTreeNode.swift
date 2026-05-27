//
//  FileTreeNode.swift
//  AgentHub
//
//  Recursive tree node model for file system navigation.
//

import Foundation

// MARK: - FileTreeNode

public struct FileTreeNode: Identifiable, Equatable, Sendable {
  /// Absolute file path — stable identity for List/OutlineGroup
  public let id: String
  public let name: String
  public let path: String
  public let isDirectory: Bool
  /// nil = not yet loaded (lazy); [] = empty directory; non-empty = loaded
  public var children: [FileTreeNode]?
  public var isExpanded: Bool = false

  public init(
    id: String,
    name: String,
    path: String,
    isDirectory: Bool,
    children: [FileTreeNode]? = nil,
    isExpanded: Bool = false
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.isDirectory = isDirectory
    self.children = children
    self.isExpanded = isExpanded
  }

  public static func == (lhs: FileTreeNode, rhs: FileTreeNode) -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - FileSearchResult

public struct FileSearchResult: Identifiable, Equatable, Sendable {
  public let id: String           // absolute path
  public let name: String
  public let relativePath: String // path relative to projectPath
  public let absolutePath: String
  public let score: Int

  public init(
    id: String,
    name: String,
    relativePath: String,
    absolutePath: String,
    score: Int
  ) {
    self.id = id
    self.name = name
    self.relativePath = relativePath
    self.absolutePath = absolutePath
    self.score = score
  }
}
