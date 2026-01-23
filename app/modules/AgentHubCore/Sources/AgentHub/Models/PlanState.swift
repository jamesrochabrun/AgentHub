//
//  PlanState.swift
//  AgentHub
//
//  Created by Assistant on 1/20/26.
//

import Foundation

// MARK: - PlanState

/// Represents a detected plan file from a session's activity history
public struct PlanState: Equatable, Sendable {
  /// Path to the plan file
  public let filePath: String

  /// File name computed from path
  public var fileName: String {
    URL(fileURLWithPath: filePath).lastPathComponent
  }

  public init(filePath: String) {
    self.filePath = filePath
  }

  /// Create from session monitor state's recent activities
  /// Scans for Write or Edit tool calls to ~/.claude/plans/*.md
  public static func from(activities: [ActivityEntry]) -> PlanState? {
    // Look for Write or Edit tool calls to plan files
    for activity in activities.reversed() {
      guard case .toolUse(let name) = activity.type,
            (name == "Write" || name == "Edit"),
            let input = activity.toolInput,
            (input.toolType == .write || input.toolType == .edit) else {
        continue
      }

      let filePath = input.filePath

      // Check if this is a plan file: ~/.claude/plans/*.md
      if filePath.contains("/.claude/plans/") && filePath.hasSuffix(".md") {
        return PlanState(filePath: filePath)
      }
    }

    return nil
  }
}
