//
//  WorktreeOrchestrationTool.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import Foundation
import os

// MARK: - Session Type

/// Type of parallel session to spawn
public enum SessionType: String, Codable, Sendable {
  /// Same task on different modules/files
  case parallel
  /// Same goal with different implementations
  case prototype
  /// Related but distinct features
  case exploration
}

// MARK: - Orchestration Session

/// Represents a single session to spawn in a worktree
public struct OrchestrationSession: Codable, Sendable, Identifiable {
  public var id: String { branchName }

  /// Brief description of the session's focus
  public let description: String

  /// Branch name for the worktree
  public let branchName: String

  /// Type of session (parallel, prototype, exploration)
  public let sessionType: SessionType

  /// Starting prompt for the Claude Code session
  public let prompt: String

  public init(
    description: String,
    branchName: String,
    sessionType: SessionType,
    prompt: String
  ) {
    self.description = description
    self.branchName = branchName
    self.sessionType = sessionType
    self.prompt = prompt
  }

  /// Custom decoder that defaults `sessionType` to `.parallel` when the field
  /// is missing or contains an unrecognized value.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.description = try container.decode(String.self, forKey: .description)
    self.branchName = try container.decode(String.self, forKey: .branchName)
    self.prompt = try container.decode(String.self, forKey: .prompt)

    if let rawType = try container.decodeIfPresent(String.self, forKey: .sessionType),
       let parsed = SessionType(rawValue: rawType) {
      self.sessionType = parsed
    } else {
      self.sessionType = .parallel
    }
  }
}

// MARK: - Orchestration Plan

/// The orchestration plan with sessions to spawn
public struct OrchestrationPlan: Codable, Sendable {
  /// Path to the target repository/module
  public let modulePath: String

  /// Sessions to spawn in parallel worktrees
  public let sessions: [OrchestrationSession]

  public init(modulePath: String, sessions: [OrchestrationSession]) {
    self.modulePath = modulePath
    self.sessions = sessions
  }
}

// MARK: - Plan Parsing

/// Utilities for parsing orchestration plans from text
public enum WorktreeOrchestrationTool {

  /// Parse orchestration plan from text containing <orchestration-plan> tags
  public static func parseFromText(_ text: String) -> OrchestrationPlan? {
    // Find the JSON between <orchestration-plan> tags
    guard let startRange = text.range(of: "<orchestration-plan>"),
          let endRange = text.range(of: "</orchestration-plan>") else {
      return nil
    }

    let jsonStart = startRange.upperBound
    let jsonEnd = endRange.lowerBound
    var jsonString = String(text[jsonStart..<jsonEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

    // Strip markdown code fences — Claude sometimes wraps JSON in ```json ... ```
    if jsonString.hasPrefix("```") {
      // Remove opening fence (```json or ```)
      if let firstNewline = jsonString.firstIndex(of: "\n") {
        jsonString = String(jsonString[jsonString.index(after: firstNewline)...])
      }
      // Remove closing fence
      if jsonString.hasSuffix("```") {
        jsonString = String(jsonString.dropLast(3))
      }
      jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Parse JSON
    guard let data = jsonString.data(using: .utf8) else {
      AppLogger.orchestration.error("Failed to convert JSON string to data")
      return nil
    }

    do {
      let plan = try JSONDecoder().decode(OrchestrationPlan.self, from: data)
      return plan
    } catch {
      AppLogger.orchestration.error("Failed to decode orchestration plan JSON: \(error)")
      AppLogger.orchestration.error("Raw JSON:\n\(jsonString)")
      assertionFailure("Orchestration plan JSON found but failed to decode: \(error)")
      return nil
    }
  }

  /// Check if text contains orchestration plan markers
  public static func containsPlanMarkers(_ text: String) -> Bool {
    return text.contains("<orchestration-plan>") && text.contains("</orchestration-plan>")
  }

  /// Fallback parser: scans text for JSON that decodes as OrchestrationPlan
  /// without requiring <orchestration-plan> XML markers.
  public static func parseJSONFromText(_ text: String) -> OrchestrationPlan? {
    // Quick check — must contain expected keys
    guard text.contains("\"modulePath\""), text.contains("\"sessions\"") else { return nil }

    let decoder = JSONDecoder()
    var candidates: [String] = []

    // Strategy 1: JSON inside markdown code fences (```json ... ``` or ``` ... ```)
    if let fenceRegex = try? NSRegularExpression(pattern: "```(?:json)?\\s*\\n([\\s\\S]*?)```", options: []) {
      let nsText = text as NSString
      let matches = fenceRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
      for match in matches {
        guard match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { continue }
        let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("{") {
          candidates.append(candidate)
        }
      }
    }

    // Strategy 2: Bare balanced { ... } blocks containing expected keys
    if candidates.isEmpty {
      var searchStart = text.startIndex
      while let openIndex = text[searchStart...].firstIndex(of: "{") {
        // Find matching closing brace using depth tracking
        var depth = 0
        var closeIndex: String.Index?
        for idx in text.indices[openIndex...] {
          if text[idx] == "{" { depth += 1 }
          else if text[idx] == "}" {
            depth -= 1
            if depth == 0 {
              closeIndex = idx
              break
            }
          }
        }
        if let close = closeIndex {
          let candidate = String(text[openIndex...close])
          if candidate.contains("\"modulePath\"") && candidate.contains("\"sessions\"") {
            candidates.append(candidate)
          }
          searchStart = text.index(after: close)
        } else {
          break
        }
      }
    }

    // Try decoding each candidate
    for candidate in candidates {
      guard let data = candidate.data(using: .utf8) else { continue }
      if let plan = try? decoder.decode(OrchestrationPlan.self, from: data) {
        AppLogger.orchestration.info("Parsed orchestration plan via JSON fallback (\(plan.sessions.count) sessions)")
        return plan
      }
    }

    return nil
  }

  /// Strip the <orchestration-plan>...</orchestration-plan> block from text,
  /// returning only the human-readable plan content.
  public static func stripPlanMarkers(_ text: String) -> String {
    guard let startRange = text.range(of: "<orchestration-plan>"),
          let endRange = text.range(of: "</orchestration-plan>") else {
      return text
    }
    var result = text
    result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
