//
//  CLISession.swift
//  AgentHub
//
//  Created by Assistant on 1/9/26.
//

import Foundation

// MARK: - CLISession

/// Represents a Claude Code CLI session detected from the ~/.claude folder
public struct CLISession: Identifiable, Sendable, Equatable, Hashable, Codable {
  public let id: String                    // Session UUID
  public let projectPath: String
  public let branchName: String?
  public let isWorktree: Bool
  public var lastActivityAt: Date
  public var messageCount: Int
  public var isActive: Bool                // Whether a process is currently running
  public var firstMessage: String?         // First user message for context
  public var lastMessage: String?          // Last user message for context
  public var slug: String?                 // Human-readable session name (e.g., "cryptic-orbiting-flame")

  public init(
    id: String,
    projectPath: String,
    branchName: String? = nil,
    isWorktree: Bool = false,
    lastActivityAt: Date = Date(),
    messageCount: Int = 0,
    isActive: Bool = false,
    firstMessage: String? = nil,
    lastMessage: String? = nil,
    slug: String? = nil
  ) {
    self.id = id
    self.projectPath = projectPath
    self.branchName = branchName
    self.isWorktree = isWorktree
    self.lastActivityAt = lastActivityAt
    self.messageCount = messageCount
    self.isActive = isActive
    self.firstMessage = firstMessage
    self.lastMessage = lastMessage
    self.slug = slug
  }

  /// Returns the first 8 characters of the session ID for display
  public var shortId: String {
    String(id.prefix(8))
  }

  /// Returns the human-readable session name, falling back to shortId if not available
  public var displayName: String {
    slug ?? shortId
  }

  /// Returns the project name (last path component)
  public var projectName: String {
    URL(fileURLWithPath: projectPath).lastPathComponent
  }
}

// MARK: - CLISessionGroup

/// Groups CLI sessions by project path
public struct CLISessionGroup: Identifiable, Sendable, Equatable {
  public var id: String { projectPath }
  public let projectPath: String
  public let projectName: String
  public var sessions: [CLISession]
  public let isWorktree: Bool
  public let mainRepoPath: String?

  public init(
    projectPath: String,
    sessions: [CLISession],
    isWorktree: Bool = false,
    mainRepoPath: String? = nil
  ) {
    self.projectPath = projectPath
    self.projectName = URL(fileURLWithPath: projectPath).lastPathComponent
    self.sessions = sessions
    self.isWorktree = isWorktree
    self.mainRepoPath = mainRepoPath
  }

  /// Number of active sessions in this group
  public var activeSessionCount: Int {
    sessions.filter { $0.isActive }.count
  }

  /// Total number of sessions in this group
  public var totalSessionCount: Int {
    sessions.count
  }

  /// Most recent activity across all sessions
  public var lastActivityAt: Date? {
    sessions.map { $0.lastActivityAt }.max()
  }
}

// MARK: - HistoryEntry

/// Represents a single entry from the history.jsonl file
public struct HistoryEntry: Decodable, Sendable {
  public let display: String
  public let timestamp: Int64
  public let project: String
  public let sessionId: String

  public var date: Date {
    Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
  }
}

// MARK: - CLISessionSourceType

/// Enum for the segmented control in SessionPickerContent
public enum CLISessionSourceType: String, CaseIterable, Sendable {
  case claw = "Claw"
  case cli = "CLI"
}

// MARK: - CLILoadingState

/// Loading state for CLI sessions view with context-specific messages
public enum CLILoadingState: Equatable, Sendable {
  case idle
  case restoringRepositories
  case addingRepository(name: String)
  case detectingWorktrees
  case scanningSessions
  case refreshing

  public var isLoading: Bool {
    self != .idle
  }

  public var message: String {
    switch self {
    case .idle: return ""
    case .restoringRepositories: return "Restoring saved repositories..."
    case .addingRepository(let name): return "Adding \(name)..."
    case .detectingWorktrees: return "Detecting worktrees..."
    case .scanningSessions: return "Scanning sessions..."
    case .refreshing: return "Refreshing..."
    }
  }
}

// MARK: - SelectedRepository

/// A repository selected by the user for CLI session monitoring
public struct SelectedRepository: Identifiable, Sendable, Equatable, Codable {
  public var id: String { path }
  public let path: String
  public let name: String
  public var worktrees: [WorktreeBranch]
  public var isExpanded: Bool

  public init(
    path: String,
    name: String? = nil,
    worktrees: [WorktreeBranch] = [],
    isExpanded: Bool = true
  ) {
    self.path = path
    self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    self.worktrees = worktrees
    self.isExpanded = isExpanded
  }

  /// Total number of sessions across all worktrees
  public var totalSessionCount: Int {
    worktrees.reduce(0) { $0 + $1.sessions.count }
  }

  /// Number of active sessions across all worktrees
  public var activeSessionCount: Int {
    worktrees.reduce(0) { $0 + $1.activeSessionCount }
  }
}

// MARK: - WorktreeBranch

/// A branch or worktree within a repository
public struct WorktreeBranch: Identifiable, Sendable, Equatable, Codable {
  public var id: String { path }
  public var name: String
  public let path: String
  public let isWorktree: Bool
  public var sessions: [CLISession]
  public var isExpanded: Bool

  public init(
    name: String,
    path: String,
    isWorktree: Bool = false,
    sessions: [CLISession] = [],
    isExpanded: Bool = false
  ) {
    self.name = name
    self.path = path
    self.isWorktree = isWorktree
    self.sessions = sessions
    self.isExpanded = isExpanded
  }

  /// Number of active sessions in this branch/worktree
  public var activeSessionCount: Int {
    sessions.filter { $0.isActive }.count
  }

  /// Most recent activity across all sessions
  public var lastActivityAt: Date? {
    sessions.map { $0.lastActivityAt }.max()
  }
}
