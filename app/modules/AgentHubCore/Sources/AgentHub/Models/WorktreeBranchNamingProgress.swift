//
//  WorktreeBranchNamingProgress.swift
//  AgentHub
//

import Foundation

public enum WorktreeBranchNamingProgress: Equatable, Sendable {
  case idle
  case preparingContext(message: String)
  case queryingModel(model: String, message: String)
  case sanitizing(message: String)
  case completed(message: String, source: WorktreeBranchNameSource, branchNames: [String])
  case failed(message: String)

  public var message: String {
    switch self {
    case .idle:
      return ""
    case .preparingContext(let message),
         .queryingModel(_, let message),
         .sanitizing(let message),
         .completed(let message, _, _),
         .failed(let message):
      return message
    }
  }

  public var activeModel: String? {
    switch self {
    case .queryingModel(let model, _):
      return model
    default:
      return nil
    }
  }

  public var source: WorktreeBranchNameSource? {
    switch self {
    case .completed(_, let source, _):
      return source
    default:
      return nil
    }
  }

  public var resolvedBranchNames: [String] {
    switch self {
    case .completed(_, _, let branchNames):
      return branchNames
    default:
      return []
    }
  }

  public var currentStepIndex: Int? {
    switch self {
    case .idle:
      return nil
    case .preparingContext:
      return 0
    case .queryingModel:
      return 1
    case .sanitizing, .completed, .failed:
      return 2
    }
  }

  public var isVisible: Bool {
    self != .idle
  }

  public var isInProgress: Bool {
    switch self {
    case .preparingContext, .queryingModel, .sanitizing:
      return true
    case .idle, .completed, .failed:
      return false
    }
  }

  public var isFinished: Bool {
    switch self {
    case .completed, .failed:
      return true
    case .idle, .preparingContext, .queryingModel, .sanitizing:
      return false
    }
  }

  public var isFallbackCompletion: Bool {
    if case .completed(_, .deterministicFallback, _) = self {
      return true
    }
    return false
  }
}
