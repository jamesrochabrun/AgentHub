//
//  GitDiffState.swift
//  AgentHub
//
//  Created by Assistant on 1/19/26.
//

import Foundation

// MARK: - GitDiffState

/// Aggregates all unstaged file changes from a git repository
public struct GitDiffState: Equatable, Sendable {
  /// List of all files with unstaged changes
  public let files: [GitDiffFileEntry]

  /// Number of files with changes
  public var fileCount: Int { files.count }

  /// Empty state with no changes
  public static let empty = GitDiffState(files: [])

  public init(files: [GitDiffFileEntry]) {
    self.files = files
  }
}

// MARK: - GitDiffFileEntry

/// Individual file with unstaged changes, including path and line statistics
public struct GitDiffFileEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// Full absolute path to the file
  public let filePath: String
  /// Path relative to repository root
  public let relativePath: String
  /// Number of lines added
  public let additions: Int
  /// Number of lines deleted
  public let deletions: Int

  /// File name extracted from path
  public var fileName: String {
    URL(fileURLWithPath: filePath).lastPathComponent
  }

  /// Directory path relative to repo root (without file name)
  public var directoryPath: String {
    URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
  }

  public init(
    id: UUID = UUID(),
    filePath: String,
    relativePath: String,
    additions: Int,
    deletions: Int
  ) {
    self.id = id
    self.filePath = filePath
    self.relativePath = relativePath
    self.additions = additions
    self.deletions = deletions
  }
}
