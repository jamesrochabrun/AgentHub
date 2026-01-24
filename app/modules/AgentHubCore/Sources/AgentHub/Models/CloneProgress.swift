//
//  CloneProgress.swift
//  AgentHub
//
//  Model for clone progress tracking
//

import Foundation

/// Progress state for repository clone operations
public enum CloneProgress: Sendable, Equatable {
  case idle
  case cloning(repository: String)
  case complete(localPath: String)
  case failed(errorMessage: String)

  /// Human-readable status message
  public var statusMessage: String {
    switch self {
    case .idle:
      return ""
    case .cloning(let repository):
      return "Cloning \(repository)..."
    case .complete(let localPath):
      let directory = (localPath as NSString).lastPathComponent
      return "Cloned: \(directory)"
    case .failed(let errorMessage):
      return errorMessage
    }
  }

  /// Whether the operation is currently in progress
  public var isInProgress: Bool {
    switch self {
    case .cloning:
      return true
    case .idle, .complete, .failed:
      return false
    }
  }

  /// Icon for the current state
  public var icon: String {
    switch self {
    case .idle:
      return "circle"
    case .cloning:
      return "arrow.down.circle"
    case .complete:
      return "checkmark.circle.fill"
    case .failed:
      return "xmark.circle.fill"
    }
  }

  /// Progress value from 0.0 to 1.0
  /// Clone progress is indeterminate, so we return approximate values
  public var progressValue: Double {
    switch self {
    case .idle:
      return 0
    case .cloning:
      return 0.5  // Indeterminate progress
    case .complete:
      return 1.0
    case .failed:
      return 0
    }
  }
}
