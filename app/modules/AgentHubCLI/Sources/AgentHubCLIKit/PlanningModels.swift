import Foundation

/// A capability category used both to tag a subtask and to describe a model's strengths.
/// The same taxonomy is scanned out of the user's prompt and out of the web-research
/// snippet so subtasks and models can be matched on a shared vocabulary.
public enum CapabilityTag: String, Codable, CaseIterable, Sendable {
  case coding
  case frontend
  case reasoning
  case testing
  case documentation
  case dataAnalysis
  case research
  case longContext
  case refactoring
  case debugging

  public var displayName: String {
    switch self {
    case .coding: return "coding"
    case .frontend: return "frontend / UI"
    case .reasoning: return "reasoning / architecture"
    case .testing: return "testing"
    case .documentation: return "documentation"
    case .dataAnalysis: return "data analysis"
    case .research: return "research"
    case .longContext: return "large-codebase / long-context work"
    case .refactoring: return "refactoring"
    case .debugging: return "debugging"
    }
  }

  /// Lowercased substrings that imply this capability when found in free text.
  var keywords: [String] {
    switch self {
    case .coding:
      return ["implement", "code", "function", "endpoint", "api", "feature", "build a", "add a", "add an", "write a", "create a"]
    case .frontend:
      return ["ui", "css", "react", "swiftui", "component", "view", "frontend", "front-end", "layout", "style", "animation", "page", "screen", "button"]
    case .reasoning:
      return ["architect", "architecture", "design", "plan", "reasoning", "strategy", "approach", "trade-off", "tradeoff", "decide", "complex"]
    case .testing:
      return ["test", "unit test", "xctest", "coverage", "spec", "assertion", "qa"]
    case .documentation:
      return ["document", "readme", "docs", "guide", "comment", "changelog", "tutorial", "write-up", "write up"]
    case .dataAnalysis:
      return ["data", "sql", "query", "csv", "analysis", "analyze", "metric", "chart", "dataset", "statistic"]
    case .research:
      return ["research", "investigate", "explore", "compare", "evaluate", "survey", "find out", "look into"]
    case .longContext:
      return ["codebase", "repo-wide", "migrate", "migration", "sweep", "entire", "whole project", "across the"]
    case .refactoring:
      return ["refactor", "rename", "restructure", "cleanup", "clean up", "extract", "reorganize", "modularize"]
    case .debugging:
      return ["debug", "fix", "bug", "crash", "error", "failure", "regression", "broken", "flaky"]
    }
  }

  /// Tags implied by `text`, returned in stable `allCases` order. Surfaced as
  /// per-subtask "focus area" hints.
  public static func tags(in text: String) -> [CapabilityTag] {
    let haystack = text.lowercased()
    return allCases.filter { tag in
      tag.keywords.contains { haystack.contains($0) }
    }
  }
}

/// A discrete unit of work parsed out of the bundled prompt.
public struct Subtask: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let tags: [CapabilityTag]

  public init(id: String, title: String, detail: String, tags: [CapabilityTag]) {
    self.id = id
    self.title = title
    self.detail = detail
    self.tags = tags
  }
}

/// An agent CLI found installed on the system.
public struct DetectedAgentCLI: Codable, Equatable, Sendable {
  public let provider: WorktreeLaunchProvider
  public let executablePath: String

  public init(provider: WorktreeLaunchProvider, executablePath: String) {
    self.provider = provider
    self.executablePath = executablePath
  }
}

/// A skill installed for a harness (read from its `skills/<name>/SKILL.md`).
public struct HarnessSkill: Codable, Equatable, Sendable {
  public let name: String
  public let description: String

  public init(name: String, description: String) {
    self.name = name
    self.description = description
  }
}

/// What a harness can actually do right now: its installed skills and configured
/// MCP servers. Detected from disk so harness assignment is grounded in real
/// tooling rather than the model/harness's general reputation.
public struct HarnessCapabilities: Codable, Equatable, Sendable {
  public let provider: WorktreeLaunchProvider
  public let skills: [HarnessSkill]
  public let mcpServers: [String]

  public init(provider: WorktreeLaunchProvider, skills: [HarnessSkill], mcpServers: [String]) {
    self.provider = provider
    self.skills = skills
    self.mcpServers = mcpServers
  }

  public var isEmpty: Bool { skills.isEmpty && mcpServers.isEmpty }

  /// The identity of every capability (skill names + MCP server names) — what a
  /// subtask is matched against. Descriptions are surfaced to the agent in the
  /// plan but deliberately kept OUT of matching, where their generic words
  /// (code, app, build, …) produce false matches.
  public var capabilityNames: [String] { skills.map(\.name) + mcpServers }
}

/// One subtask mapped to an installed agent harness (Claude Code / Codex).
///
/// `assignedProvider` is the harness AgentHub will launch — `nil` means the
/// choice is deferred to the calling agent (more than one harness installed, or
/// none). There is no model field: AgentHub launches the harness, not a model.
public struct PlanAssignment: Codable, Equatable, Sendable {
  public let subtask: Subtask
  public let assignedProvider: WorktreeLaunchProvider?
  /// Names of the assigned harness's skills/MCP servers that matched this
  /// subtask and drove the suggestion (empty when the match was weak).
  public let matchedCapabilities: [String]
  public let rationale: String
  public let instructions: String
  public let branchSuggestion: String

  public init(
    subtask: Subtask,
    assignedProvider: WorktreeLaunchProvider?,
    matchedCapabilities: [String] = [],
    rationale: String,
    instructions: String,
    branchSuggestion: String
  ) {
    self.subtask = subtask
    self.assignedProvider = assignedProvider
    self.matchedCapabilities = matchedCapabilities
    self.rationale = rationale
    self.instructions = instructions
    self.branchSuggestion = branchSuggestion
  }
}

/// The full delegation plan returned by the planning tool.
public struct DelegationPlan: Codable, Equatable, Sendable {
  public let originalPrompt: String
  public let repositoryPath: String?
  public let detectedCLIs: [DetectedAgentCLI]
  /// The real capabilities (skills + MCP servers) of each detected harness, so
  /// the agent can confirm or override the suggested assignment from real data.
  public let harnessCapabilities: [HarnessCapabilities]
  public let assignments: [PlanAssignment]
  public let notes: [String]

  public init(
    originalPrompt: String,
    repositoryPath: String?,
    detectedCLIs: [DetectedAgentCLI],
    harnessCapabilities: [HarnessCapabilities],
    assignments: [PlanAssignment],
    notes: [String]
  ) {
    self.originalPrompt = originalPrompt
    self.repositoryPath = repositoryPath
    self.detectedCLIs = detectedCLIs
    self.harnessCapabilities = harnessCapabilities
    self.assignments = assignments
    self.notes = notes
  }
}
