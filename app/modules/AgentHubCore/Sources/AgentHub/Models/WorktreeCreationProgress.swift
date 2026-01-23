//
//  WorktreeCreationProgress.swift
//  AgentHub
//
//  Created by Assistant on 1/12/26.
//

import Foundation

/// Progress state for worktree creation operation
/// Tracks real-time progress based on git's stderr output
public enum WorktreeCreationProgress: Equatable, Sendable {
  case idle
  case preparing(message: String)
  case updatingFiles(current: Int, total: Int)
  case completed(path: String)
  case failed(error: String)

  /// Progress value from 0.0 to 1.0
  public var progressValue: Double {
    switch self {
    case .idle:
      return 0
    case .preparing:
      return 0.05  // Small initial progress
    case .updatingFiles(let current, let total):
      return total > 0 ? Double(current) / Double(total) : 0
    case .completed:
      return 1.0
    case .failed:
      return 0
    }
  }

  /// Human-readable status message
  public var statusMessage: String {
    switch self {
    case .idle:
      return ""
    case .preparing(let msg):
      return msg
    case .updatingFiles(let current, let total):
      return "Updating files: \(current)/\(total)"
    case .completed(let path):
      let directory = (path as NSString).lastPathComponent
      return "Created: \(directory)"
    case .failed(let error):
      return error
    }
  }

  /// Whether the operation is currently in progress
  public var isInProgress: Bool {
    switch self {
    case .idle, .completed, .failed:
      return false
    case .preparing, .updatingFiles:
      return true
    }
  }

  /// Icon for the current state
  public var icon: String {
    switch self {
    case .idle:
      return "circle"
    case .preparing:
      return "arrow.triangle.branch"
    case .updatingFiles:
      return "doc.on.doc"
    case .completed:
      return "checkmark.circle.fill"
    case .failed:
      return "xmark.circle.fill"
    }
  }
}
