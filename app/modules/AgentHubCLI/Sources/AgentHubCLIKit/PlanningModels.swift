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

  /// Tags implied by `text`, returned in stable `allCases` order.
  public static func tags(in text: String) -> [CapabilityTag] {
    let haystack = text.lowercased()
    return allCases.filter { tag in
      tag.keywords.contains { haystack.contains($0) }
    }
  }

  /// Tags ranked by how often their keywords appear in `text` (descending),
  /// ties broken by `allCases` order. Used to derive strengths from a research snippet.
  public static func rankedTags(in text: String) -> [CapabilityTag] {
    let haystack = text.lowercased()
    let scored = allCases.map { tag -> (CapabilityTag, Int) in
      let count = tag.keywords.reduce(0) { partial, keyword in
        partial + haystack.components(separatedBy: keyword).count - 1
      }
      return (tag, count)
    }
    return scored
      .filter { $0.1 > 0 }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return allCases.firstIndex(of: lhs.0)! < allCases.firstIndex(of: rhs.0)!
      }
      .map(\.0)
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

/// The researched capability profile of a provider's latest model.
public struct ModelCapabilityProfile: Codable, Equatable, Sendable {
  public let provider: WorktreeLaunchProvider
  public let model: String
  public let strengths: [CapabilityTag]
  public let summary: String
  public let sourceURL: String?
  public let sourcedFromWeb: Bool

  public init(
    provider: WorktreeLaunchProvider,
    model: String,
    strengths: [CapabilityTag],
    summary: String,
    sourceURL: String?,
    sourcedFromWeb: Bool
  ) {
    self.provider = provider
    self.model = model
    self.strengths = strengths
    self.summary = summary
    self.sourceURL = sourceURL
    self.sourcedFromWeb = sourcedFromWeb
  }

  /// Weight of `tag` for this profile: higher when the strength is ranked earlier,
  /// zero when the model does not list it as a strength.
  public func weight(for tag: CapabilityTag) -> Int {
    guard let index = strengths.firstIndex(of: tag) else { return 0 }
    return strengths.count - index
  }
}

/// One subtask mapped to the best-suited installed agent.
public struct PlanAssignment: Codable, Equatable, Sendable {
  public let subtask: Subtask
  public let assignedProvider: WorktreeLaunchProvider?
  public let assignedModel: String?
  public let matchedStrengths: [CapabilityTag]
  public let rationale: String
  public let instructions: String
  public let branchSuggestion: String

  public init(
    subtask: Subtask,
    assignedProvider: WorktreeLaunchProvider?,
    assignedModel: String?,
    matchedStrengths: [CapabilityTag],
    rationale: String,
    instructions: String,
    branchSuggestion: String
  ) {
    self.subtask = subtask
    self.assignedProvider = assignedProvider
    self.assignedModel = assignedModel
    self.matchedStrengths = matchedStrengths
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
  public let modelProfiles: [ModelCapabilityProfile]
  public let assignments: [PlanAssignment]
  public let notes: [String]

  public init(
    originalPrompt: String,
    repositoryPath: String?,
    detectedCLIs: [DetectedAgentCLI],
    modelProfiles: [ModelCapabilityProfile],
    assignments: [PlanAssignment],
    notes: [String]
  ) {
    self.originalPrompt = originalPrompt
    self.repositoryPath = repositoryPath
    self.detectedCLIs = detectedCLIs
    self.modelProfiles = modelProfiles
    self.assignments = assignments
    self.notes = notes
  }
}
