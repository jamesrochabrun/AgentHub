//
//  GitDiffState.swift
//  AgentHub
//
//  Created by Assistant on 1/19/26.
//

import Foundation

// MARK: - DiffMode

/// Represents the type of diff to display
public enum DiffMode: String, CaseIterable, Identifiable, Sendable {
  // Declaration order drives `allCases` and the diff tab picker. Ordered cheapest-to-load /
  // preferred first: branch & staged are fast tree comparisons; unstaged is the expensive
  // index→workdir scan (and slowest on large worktrees), so it goes last. Matches the
  // auto-select ordering in GitDiffView.
  case branch = "Branch"
  case staged = "Staged"
  case unstaged = "Unstaged"

  public var id: String { rawValue }

  public var icon: String {
    switch self {
    case .unstaged: return "pencil.circle"
    case .staged: return "checkmark.circle"
    case .branch: return "arrow.triangle.branch"
    }
  }

  public var emptyStateTitle: String {
    switch self {
    case .unstaged: return "No Unstaged Changes"
    case .staged: return "No Staged Changes"
    case .branch: return "No Branch Changes"
    }
  }

  public var emptyStateDescription: String {
    switch self {
    case .unstaged: return "Your working directory is clean."
    case .staged: return "No files have been staged for commit."
    case .branch: return "No changes compared to the base branch."
    }
  }

  public var loadingMessage: String {
    switch self {
    case .unstaged: return "Loading unstaged changes..."
    case .staged: return "Loading staged changes..."
    case .branch: return "Loading branch changes..."
    }
  }
}

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

// MARK: - GitDiffRenderPolicy

public struct GitDiffRenderPolicy: Equatable, Sendable {
  public static let `default` = GitDiffRenderPolicy(
    maxFullContentBytes: 512 * 1024,
    maxPatchBytes: 2 * 1024 * 1024
  )

  public let maxFullContentBytes: UInt64
  public let maxPatchBytes: UInt64

  public init(
    maxFullContentBytes: UInt64,
    maxPatchBytes: UInt64 = 2 * 1024 * 1024
  ) {
    self.maxFullContentBytes = maxFullContentBytes
    self.maxPatchBytes = maxPatchBytes
  }
}

// MARK: - GitDiffRenderMode

public enum GitDiffRenderMode: String, Equatable, Sendable {
  case fullFile
  case limitedHunks
}

// MARK: - GitDiffRenderPayload

public struct GitDiffRenderPayload: Equatable, Sendable {
  public let oldContent: String
  public let newContent: String
  public let isLimitedContext: Bool
  public let limitedContextReason: String?
  public let renderMode: GitDiffRenderMode

  public init(
    oldContent: String,
    newContent: String,
    isLimitedContext: Bool = false,
    limitedContextReason: String? = nil,
    renderMode: GitDiffRenderMode? = nil
  ) {
    self.oldContent = oldContent
    self.newContent = newContent
    self.isLimitedContext = isLimitedContext
    self.limitedContextReason = limitedContextReason
    self.renderMode = renderMode ?? (isLimitedContext ? .limitedHunks : .fullFile)
  }
}

// MARK: - GitDiffFileStatus

public enum GitDiffFileStatus: String, Equatable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case untracked
  case typeChanged
  case conflicted
  case unknown
}

// MARK: - GitDiffFileEntry

/// Individual file with unstaged changes, including path and line statistics
public struct GitDiffFileEntry: Identifiable, Equatable, Sendable {
  public let id: String
  /// Full absolute path to the file
  public let filePath: String
  /// Path relative to repository root
  public let relativePath: String
  /// Previous path for renamed or copied files, relative to repository root.
  public let oldRelativePath: String?
  /// Number of lines added
  public let additions: Int
  /// Number of lines deleted
  public let deletions: Int
  /// Git status for this entry.
  public let status: GitDiffFileStatus
  /// Whether Git identified the file as binary.
  public let isBinary: Bool

  /// File name extracted from path
  public var fileName: String {
    URL(fileURLWithPath: filePath).lastPathComponent
  }

  /// Directory path relative to repo root (without file name)
  public var directoryPath: String {
    URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
  }

  /// File extensions that WKWebView can render standalone (no build step needed)
  private static let webRenderableExtensions: Set<String> = [
    "html", "htm", "svg"
  ]

  /// Whether this file can be previewed as rendered web content in a WebView
  public var isWebRenderable: Bool {
    let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
    return Self.webRenderableExtensions.contains(ext)
  }

  public init(
    id: String? = nil,
    filePath: String,
    relativePath: String,
    oldRelativePath: String? = nil,
    additions: Int,
    deletions: Int,
    status: GitDiffFileStatus = .modified,
    isBinary: Bool = false
  ) {
    self.filePath = filePath
    self.relativePath = relativePath
    self.oldRelativePath = oldRelativePath
    self.additions = additions
    self.deletions = deletions
    self.status = status
    self.isBinary = isBinary
    self.id = id ?? Self.makeStableId(
      relativePath: relativePath,
      oldRelativePath: oldRelativePath,
      status: status
    )
  }

  private static func makeStableId(
    relativePath: String,
    oldRelativePath: String?,
    status: GitDiffFileStatus
  ) -> String {
    if let oldRelativePath, !oldRelativePath.isEmpty, oldRelativePath != relativePath {
      return "\(status.rawValue):\(oldRelativePath)->\(relativePath)"
    }
    return "\(status.rawValue):\(relativePath)"
  }
}
