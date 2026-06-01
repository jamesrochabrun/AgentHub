import Foundation

/// Turns a bundled, multi-part prompt into a concrete delegation plan: discrete subtasks,
/// the best-suited installed agent for each, and per-agent instructions.
public protocol AgentHubPlanning: Sendable {
  func buildPlan(
    prompt: String,
    providedSubtasks: [String],
    repositoryPath: String?
  ) async -> DelegationPlan
}

/// Default planner. Composes the decomposer, CLI detector, and capability researcher
/// (all injected as protocols so the orchestration is unit-testable with mocks) and
/// applies deterministic strength-based matching.
public struct AgentHubPlanningService: AgentHubPlanning {
  private let detector: AgentCLIDetecting
  private let research: ModelCapabilityResearching
  private let decomposer: TaskDecomposing

  public init(
    detector: AgentCLIDetecting = AgentCLIDetector(),
    research: ModelCapabilityResearching = WebModelCapabilityResearchService(),
    decomposer: TaskDecomposing = SemanticTaskDecomposer()
  ) {
    self.detector = detector
    self.research = research
    self.decomposer = decomposer
  }

  public func buildPlan(
    prompt: String,
    providedSubtasks: [String],
    repositoryPath: String?
  ) async -> DelegationPlan {
    let subtasks = resolveSubtasks(prompt: prompt, providedSubtasks: providedSubtasks)
    let detectedCLIs = await detector.detectInstalledCLIs()
    let profiles = await researchProfiles(for: detectedCLIs)
    let profilesByProvider = Dictionary(
      profiles.map { ($0.provider, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    let branchSuggestions = Self.uniqueBranchSuggestions(for: subtasks)
    let assignments = zip(subtasks, branchSuggestions).map { subtask, branch in
      makeAssignment(
        for: subtask,
        branchSuggestion: branch,
        detectedCLIs: detectedCLIs,
        profilesByProvider: profilesByProvider
      )
    }

    return DelegationPlan(
      originalPrompt: prompt,
      repositoryPath: repositoryPath,
      detectedCLIs: detectedCLIs,
      modelProfiles: profiles,
      assignments: assignments,
      notes: makeNotes(detectedCLIs: detectedCLIs, profiles: profiles)
    )
  }

  // MARK: - Subtasks

  private func resolveSubtasks(prompt: String, providedSubtasks: [String]) -> [Subtask] {
    let explicit = providedSubtasks
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard explicit.isEmpty else {
      return explicit.enumerated().map { index, text in
        Subtask(
          id: "task-\(index + 1)",
          title: Self.title(from: text),
          detail: text,
          tags: SemanticTaskDecomposer.tags(for: text)
        )
      }
    }
    return decomposer.decompose(prompt: prompt)
  }

  // MARK: - Research

  private func researchProfiles(for clis: [DetectedAgentCLI]) async -> [ModelCapabilityProfile] {
    guard !clis.isEmpty else { return [] }
    // Capability lookup is local by default; an injected researcher may opt into web lookup.
    let research = self.research
    let collected = await withTaskGroup(of: ModelCapabilityProfile.self) { group in
      for cli in clis {
        let provider = cli.provider
        group.addTask { await research.researchCapabilities(for: provider) }
      }
      var results: [ModelCapabilityProfile] = []
      for await profile in group {
        results.append(profile)
      }
      return results
    }
    // Preserve detection order regardless of which search finished first.
    return clis.compactMap { cli in collected.first { $0.provider == cli.provider } }
  }

  // MARK: - Matching

  private func makeAssignment(
    for subtask: Subtask,
    branchSuggestion: String,
    detectedCLIs: [DetectedAgentCLI],
    profilesByProvider: [WorktreeLaunchProvider: ModelCapabilityProfile]
  ) -> PlanAssignment {
    guard !detectedCLIs.isEmpty else {
      return PlanAssignment(
        subtask: subtask,
        assignedProvider: nil,
        assignedModel: nil,
        matchedStrengths: [],
        rationale: "No agent CLI detected; install Claude Code or Codex to delegate this subtask.",
        instructions: Self.instructions(for: subtask, model: nil, branch: branchSuggestion),
        branchSuggestion: branchSuggestion
      )
    }

    // Score each installed CLI; the first CLI in detection order wins ties so results
    // are stable.
    let best = detectedCLIs
      .map { cli -> (cli: DetectedAgentCLI, score: Int) in
        let profile = profilesByProvider[cli.provider]
        let score = subtask.tags.reduce(0) { $0 + (profile?.weight(for: $1) ?? 0) }
        return (cli, score)
      }
      .max { $0.score < $1.score }!

    let profile = profilesByProvider[best.cli.provider]
    let matched = subtask.tags.filter { (profile?.weight(for: $0) ?? 0) > 0 }
    let model = profile?.model ?? best.cli.provider.rawValue

    return PlanAssignment(
      subtask: subtask,
      assignedProvider: best.cli.provider,
      assignedModel: model,
      matchedStrengths: matched,
      rationale: Self.rationale(model: model, matched: matched, score: best.score),
      instructions: Self.instructions(for: subtask, model: model, branch: branchSuggestion),
      branchSuggestion: branchSuggestion
    )
  }

  private func makeNotes(
    detectedCLIs: [DetectedAgentCLI],
    profiles: [ModelCapabilityProfile]
  ) -> [String] {
    var notes: [String] = []

    switch detectedCLIs.count {
    case 0:
      notes.append("No agent CLIs (claude, codex) were found on PATH. Subtasks are left unassigned — install Claude Code and/or Codex to enable delegation.")
    case 1:
      let model = profiles.first?.model ?? detectedCLIs[0].provider.rawValue
      notes.append("Only one agent CLI was detected (\(model)); every subtask is assigned to it.")
    default:
      notes.append("\(detectedCLIs.count) agent CLIs detected; subtasks were matched to the model whose strengths best fit each one.")
    }

    for profile in profiles {
      let origin = profile.sourcedFromWeb
        ? "from web search (\(profile.sourceURL ?? "source"))"
        : "from local curated profile"
      notes.append("\(profile.model) strengths \(origin): \(profile.strengths.map(\.displayName).joined(separator: ", ")).")
    }

    notes.append("This plan is advisory. If the user explicitly approves worktree creation, create one worktree per approved subtask with agenthub_create_worktree_sessions.")
    return notes
  }

  // MARK: - Text helpers

  static func title(from text: String) -> String {
    let words = text
      .replacingOccurrences(of: "\n", with: " ")
      .split(separator: " ")
      .prefix(8)
    let joined = words.joined(separator: " ")
    let stripped = joined.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
    return stripped.isEmpty ? text : stripped
  }

  static func branchSuggestion(for subtask: Subtask) -> String {
    let slugSource = subtask.title.lowercased()
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789 -")
    let filtered = String(slugSource.unicodeScalars.filter { allowed.contains($0) })
    let words = filtered
      .split(whereSeparator: { $0 == " " || $0 == "-" })
      .prefix(5)
    let slug = words.joined(separator: "-")
    let cleaned = slug.isEmpty ? subtask.id : slug
    return WorktreeNaming.sanitizeBranchName("agent/\(cleaned)")
  }

  static func uniqueBranchSuggestions(for subtasks: [Subtask]) -> [String] {
    var used = Set<String>()
    return subtasks.enumerated().map { index, subtask in
      let base = branchSuggestion(for: subtask)
      var candidate = base
      if used.contains(candidate) {
        let suffix = branchSuffix(from: subtask.id)
        let fallbackSuffix = suffix.isEmpty ? "task-\(index + 1)" : suffix
        candidate = WorktreeNaming.sanitizeBranchName("\(base)-\(fallbackSuffix)")

        var attempt = 2
        while used.contains(candidate) {
          candidate = WorktreeNaming.sanitizeBranchName("\(base)-task-\(index + 1)-\(attempt)")
          attempt += 1
        }
      }
      used.insert(candidate)
      return candidate
    }
  }

  private static func branchSuffix(from value: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    let lowercased = value.lowercased().replacingOccurrences(of: " ", with: "-")
    return String(lowercased.unicodeScalars.filter { allowed.contains($0) })
  }

  static func rationale(model: String, matched: [CapabilityTag], score: Int) -> String {
    guard !matched.isEmpty else {
      return "Assigned to \(model) (no specific strength overlap; best available match)."
    }
    let strengths = matched.map(\.displayName).joined(separator: ", ")
    return "Assigned to \(model) — strong in \(strengths) (match score \(score))."
  }

  static func instructions(for subtask: Subtask, model: String?, branch: String) -> String {
    let agent = model.map { "Use \($0). " } ?? "No agent assigned — pick an installed CLI before starting. "
    let focus = subtask.tags.map(\.displayName).joined(separator: ", ")
    return """
    \(agent)Work only on this subtask: \(subtask.detail)
    Branch: \(branch). Stay scoped to this subtask and avoid editing files owned by other parallel subtasks.
    Primary focus areas: \(focus).
    When done, ensure the change builds and its tests pass before handing off.
    """
  }
}
