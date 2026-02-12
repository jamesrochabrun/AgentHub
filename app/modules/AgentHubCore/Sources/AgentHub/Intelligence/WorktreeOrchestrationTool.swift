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

// MARK: - Tool Schema

/// Schema definition for the create_parallel_worktrees tool
public enum WorktreeOrchestrationTool {

  /// The tool name that Claude will call
  public static let toolName = "create_parallel_worktrees"

  /// JSON Schema for the tool input
  public static let inputSchema: [String: Any] = [
    "type": "object",
    "properties": [
      "modulePath": [
        "type": "string",
        "description": "Absolute path to the repository or module"
      ],
      "sessions": [
        "type": "array",
        "description": "Sessions to spawn immediately in parallel worktrees",
        "items": [
          "type": "object",
          "properties": [
            "description": [
              "type": "string",
              "description": "Brief description of the session's focus"
            ],
            "branchName": [
              "type": "string",
              "description": "Unique branch name (lowercase with hyphens)"
            ],
            "sessionType": [
              "type": "string",
              "enum": ["parallel", "prototype", "exploration"],
              "description": "Type of session: parallel (same task, different targets), prototype (same goal, different approach), exploration (related features)"
            ],
            "prompt": [
              "type": "string",
              "description": "Starting prompt for the Claude Code session"
            ]
          ],
          "required": ["description", "branchName", "sessionType", "prompt"]
        ]
      ]
    ],
    "required": ["modulePath", "sessions"]
  ]

  /// System prompt for orchestration mode
  public static let systemPrompt = """
    You are a session orchestrator. Your ONLY job is to output a JSON plan.

    CRITICAL RULES:
    1. DO NOT ask questions
    2. ONLY output the JSON plan wrapped in <orchestration-plan> tags

    BRANCH NAME GENERATION:
    Generate unique, memorable branch names using this format: {module}-{word}-{word}
    - Use creative, fun words (animals, colors, food, nature, etc.)
    - Each session MUST have a different word combination
    - Keep it lowercase with hyphens
    - Examples: mathgame-cosmic-penguin, agenthub-dancing-waffle, myapp-golden-phoenix

    PROMPT GENERATION RULES:

    **For "prototype" sessions** (same goal, different approaches):
    - ALL sessions get the EXACT SAME prompt
    - Extract the core task/feature from the user's request
    - Remove any "try X versions" or "different approaches" phrasing
    - Each Claude will independently decide their implementation approach
    - Example: "Implement caching, try 3 versions" → prompt: "Implement caching" for ALL sessions

    **For "parallel" sessions** (same task, different targets):
    - Each session gets a DIFFERENT prompt targeting a specific module/file
    - Divide the work across the codebase
    - Example: "Add logging everywhere" → prompts target different modules

    **For "exploration" sessions** (related but distinct tasks):
    - Each session gets a DIFFERENT prompt for a distinct subtask
    - Break the user's request into independent pieces of work
    - Example: "Analyze and improve the app" → different improvement areas

    OUTPUT FORMAT:
    <orchestration-plan>
    {
      "modulePath": "/absolute/path/to/repository",
      "sessions": [
        {
          "description": "Brief description of session focus",
          "branchName": "feature-branch-name",
          "sessionType": "prototype|parallel|exploration",
          "prompt": "The starting prompt for this Claude session"
        }
      ]
    }
    </orchestration-plan>

    IMPORTANT:
    - The modulePath MUST be the working directory provided in the context
    - Output the JSON immediately without asking questions
    - After the JSON, briefly confirm what sessions you're creating
    """

  /// Parse tool input from Claude's response (for tool call approach)
  public static func parseInput(_ input: [String: Any]) -> OrchestrationPlan? {
    guard let modulePath = input["modulePath"] as? String,
          let sessionsArray = input["sessions"] as? [[String: Any]] else {
      return nil
    }

    let sessions = sessionsArray.compactMap { sessionDict -> OrchestrationSession? in
      guard let description = sessionDict["description"] as? String,
            let branchName = sessionDict["branchName"] as? String,
            let sessionTypeStr = sessionDict["sessionType"] as? String,
            let sessionType = SessionType(rawValue: sessionTypeStr),
            let prompt = sessionDict["prompt"] as? String else {
        return nil
      }

      return OrchestrationSession(
        description: description,
        branchName: branchName,
        sessionType: sessionType,
        prompt: prompt
      )
    }

    return OrchestrationPlan(modulePath: modulePath, sessions: sessions)
  }

  /// Parse orchestration plan from text containing <orchestration-plan> tags
  public static func parseFromText(_ text: String) -> OrchestrationPlan? {
    // Find the JSON between <orchestration-plan> tags
    guard let startRange = text.range(of: "<orchestration-plan>"),
          let endRange = text.range(of: "</orchestration-plan>") else {
      return nil
    }

    let jsonStart = startRange.upperBound
    let jsonEnd = endRange.lowerBound
    let jsonString = String(text[jsonStart..<jsonEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

    // Parse JSON
    guard let data = jsonString.data(using: .utf8) else {
      AppLogger.orchestration.error("Failed to convert JSON string to data")
      return nil
    }

    do {
      let plan = try JSONDecoder().decode(OrchestrationPlan.self, from: data)
      return plan
    } catch {
      AppLogger.orchestration.error("Failed to decode JSON: \(error.localizedDescription)")
      return nil
    }
  }

  /// Check if text contains orchestration plan markers
  public static func containsPlanMarkers(_ text: String) -> Bool {
    return text.contains("<orchestration-plan>") && text.contains("</orchestration-plan>")
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
