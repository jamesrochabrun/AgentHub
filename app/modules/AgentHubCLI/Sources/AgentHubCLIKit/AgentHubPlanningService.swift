import Foundation

/// Turns a bundled, multi-part prompt into a delegation plan: discrete subtasks,
/// a suggested agent harness (Claude Code / Codex) for each grounded in that
/// harness's real skills + MCP tools, a branch suggestion, and per-subtask launch
/// instructions.
public protocol AgentHubPlanning: Sendable {
  func buildPlan(
    prompt: String,
    providedSubtasks: [String],
    repositoryPath: String?
  ) async -> DelegationPlan
}

/// Default planner.
///
/// AgentHub launches an agent **harness** (Claude Code or Codex) — it cannot pick
/// or configure the underlying model — so the plan never names a model, only the
/// harness. Task decomposition is the calling agent's job (it passes the subtasks
/// it inferred). Harness selection is suggested by matching each subtask against
/// the harness's *actual* installed skills and MCP servers (not its reputation);
/// the calling agent can override using the full capability list in the plan.
public struct AgentHubPlanningService: AgentHubPlanning {
  private let detector: AgentCLIDetecting
  private let capabilityDetector: HarnessCapabilityDetecting

  public init(
    detector: AgentCLIDetecting = AgentCLIDetector(),
    capabilityDetector: HarnessCapabilityDetecting = HarnessCapabilityDetector()
  ) {
    self.detector = detector
    self.capabilityDetector = capabilityDetector
  }

  public func buildPlan(
    prompt: String,
    providedSubtasks: [String],
    repositoryPath: String?
  ) async -> DelegationPlan {
    let subtasks = resolveSubtasks(prompt: prompt, providedSubtasks: providedSubtasks)
    let detectedCLIs = await detector.detectInstalledCLIs()
    let capabilities = await detectCapabilities(for: detectedCLIs, repositoryPath: repositoryPath)
    let capabilitiesByProvider = Dictionary(
      capabilities.map { ($0.provider, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    let branchSuggestions = Self.uniqueBranchSuggestions(for: subtasks)
    let assignments = zip(subtasks, branchSuggestions).map { subtask, branch in
      makeAssignment(
        for: subtask,
        branchSuggestion: branch,
        detectedCLIs: detectedCLIs,
        capabilitiesByProvider: capabilitiesByProvider
      )
    }

    return DelegationPlan(
      originalPrompt: prompt,
      repositoryPath: repositoryPath,
      detectedCLIs: detectedCLIs,
      harnessCapabilities: capabilities,
      assignments: assignments,
      notes: makeNotes(detectedCLIs: detectedCLIs, capabilities: capabilities)
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
          tags: Self.tags(for: text)
        )
      }
    }
    // Decomposition is the calling agent's job: it infers independent subtasks and
    // passes them as `subtasks`. With none provided we do NOT statically split —
    // the whole prompt becomes a single task.
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return [
      Subtask(
        id: "task-1",
        title: Self.title(from: trimmed),
        detail: trimmed,
        tags: Self.tags(for: trimmed)
      )
    ]
  }

  /// Capability tags implied by `text`, surfaced only as per-subtask "focus area"
  /// hints; defaults to `.coding` for this developer-oriented tool.
  static func tags(for text: String) -> [CapabilityTag] {
    let tags = CapabilityTag.tags(in: text)
    return tags.isEmpty ? [.coding] : tags
  }

  // MARK: - Capability detection

  private func detectCapabilities(
    for clis: [DetectedAgentCLI],
    repositoryPath: String?
  ) async -> [HarnessCapabilities] {
    guard !clis.isEmpty else { return [] }
    let capabilityDetector = self.capabilityDetector
    let collected = await withTaskGroup(of: HarnessCapabilities.self) { group in
      for cli in clis {
        let provider = cli.provider
        group.addTask {
          await capabilityDetector.detectCapabilities(for: provider, repositoryPath: repositoryPath)
        }
      }
      var results: [HarnessCapabilities] = []
      for await capabilities in group {
        results.append(capabilities)
      }
      return results
    }
    // Preserve detection order regardless of which finished first.
    return clis.compactMap { cli in collected.first { $0.provider == cli.provider } }
  }

  // MARK: - Harness assignment

  private func makeAssignment(
    for subtask: Subtask,
    branchSuggestion: String,
    detectedCLIs: [DetectedAgentCLI],
    capabilitiesByProvider: [WorktreeLaunchProvider: HarnessCapabilities]
  ) -> PlanAssignment {
    // No harness installed.
    guard !detectedCLIs.isEmpty else {
      return PlanAssignment(
        subtask: subtask,
        assignedProvider: nil,
        rationale: "No agent harness detected; install Claude Code or Codex to delegate this subtask.",
        instructions: Self.unassignedInstructions(for: subtask, branch: branchSuggestion),
        branchSuggestion: branchSuggestion
      )
    }

    // Exactly one harness installed: everything goes to it.
    if detectedCLIs.count == 1 {
      let provider = detectedCLIs[0].provider
      return PlanAssignment(
        subtask: subtask,
        assignedProvider: provider,
        rationale: "Assigned to \(provider.harnessName) — the only installed agent harness.",
        instructions: Self.instructions(for: subtask, harness: provider.harnessName, branch: branchSuggestion),
        branchSuggestion: branchSuggestion
      )
    }

    // Multiple harnesses: suggest the one whose real skills/MCP tools fit best.
    let suggestion = Self.suggestHarness(
      for: subtask,
      detectedCLIs: detectedCLIs,
      capabilitiesByProvider: capabilitiesByProvider
    )
    guard let provider = suggestion.provider else {
      // No capability signal either way → leave the choice to the agent.
      let names = detectedCLIs.map(\.provider.harnessName).joined(separator: " or ")
      return PlanAssignment(
        subtask: subtask,
        assignedProvider: nil,
        rationale: "No clear capability match — choose \(names) using the harness capabilities listed in the plan.",
        instructions: Self.deferredInstructions(for: subtask, harnessNames: names, branch: branchSuggestion),
        branchSuggestion: branchSuggestion
      )
    }

    let matchText = suggestion.matched.isEmpty ? "" : " — matches \(suggestion.matched.joined(separator: ", "))"
    return PlanAssignment(
      subtask: subtask,
      assignedProvider: provider,
      matchedCapabilities: suggestion.matched,
      rationale: "Suggested \(provider.harnessName)\(matchText). Override if another harness's skills/tools fit this subtask better.",
      instructions: Self.instructions(for: subtask, harness: provider.harnessName, branch: branchSuggestion),
      branchSuggestion: branchSuggestion
    )
  }

  /// Suggests the harness whose capability NAMES (skills + MCP servers) best match
  /// the subtask, with prefix tolerance (so `profile` ↔ `profiler`, `figma` ↔
  /// `figma-implement-design`). Matching against names — not descriptions — keeps
  /// it precise; ties break by detection order. Returns `nil` provider when no
  /// capability clearly matches, so the agent decides from the surfaced data
  /// rather than the planner guessing wrong.
  static func suggestHarness(
    for subtask: Subtask,
    detectedCLIs: [DetectedAgentCLI],
    capabilitiesByProvider: [WorktreeLaunchProvider: HarnessCapabilities]
  ) -> (provider: WorktreeLaunchProvider?, matched: [String]) {
    let need = signalTokens(
      from: "\(subtask.title) \(subtask.detail) \(subtask.tags.map(\.displayName).joined(separator: " "))"
    )

    var best: (provider: WorktreeLaunchProvider, matched: [String])?
    for cli in detectedCLIs {
      let matched = (capabilitiesByProvider[cli.provider]?.capabilityNames ?? [])
        .filter { capabilityMatches(need: need, capabilityName: $0) }
      if best == nil || matched.count > best!.matched.count {
        best = (cli.provider, matched)
      }
    }

    guard let best, !best.matched.isEmpty else { return (nil, []) }
    return (best.provider, best.matched)
  }

  /// A capability matches when any of its name tokens shares a prefix with any of
  /// the subtask's signal tokens (both ≥4 chars).
  static func capabilityMatches(need: Set<String>, capabilityName: String) -> Bool {
    let capabilityTokens = signalTokens(from: capabilityName)
    for needToken in need {
      for capabilityToken in capabilityTokens where tokensMatch(needToken, capabilityToken) {
        return true
      }
    }
    return false
  }

  static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    guard lhs.count >= 4, rhs.count >= 4 else { return false }
    return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
  }

  /// Significant lowercased terms (≥4 chars, non-generic). Drops generic action
  /// words that appear in both subtasks and tool names (implement, design, …) so a
  /// capability is only matched on its distinctive part (`figma`, `xctrace`, …).
  static func signalTokens(from text: String) -> Set<String> {
    let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
    return Set(words.filter { $0.count >= 4 && !stopwords.contains($0) })
  }

  static let stopwords: Set<String> = [
    "this", "that", "with", "from", "into", "your", "they", "them", "then", "than",
    "when", "what", "which", "will", "would", "should", "could", "have", "need",
    "make", "makes", "want", "each", "also", "only", "just", "like", "using", "used",
    "ensure", "stay", "scoped", "work", "handing", "before", "after", "across",
    "other", "files", "file", "owned", "parallel", "update", "create", "creating",
    "review", "areas", "focus", "primary", "project", "projects", "change",
    "changes", "code", "coding", "swift", "apps", "application", "agent", "agents",
    "skill", "skills", "feature", "features", "help", "helps", "guide", "provide",
    "provides", "including", "includes", "where", "both", "branch", "handoff",
    "build", "builds", "building", "user", "users", "support", "supports", "their",
    "implement", "implementing", "design", "designing", "designs", "thing", "things",
    "show", "shows", "adds", "added", "task", "tasks", "subtask", "subtasks",
    "tool", "tools", "server", "servers", "mode", "manager", "runtime", "primary",
    "find", "finds", "finding", "found", "identify", "produce", "report",
  ]

  // MARK: - Text helpers

  private func makeNotes(
    detectedCLIs: [DetectedAgentCLI],
    capabilities: [HarnessCapabilities]
  ) -> [String] {
    var notes: [String] = []
    switch detectedCLIs.count {
    case 0:
      notes.append("No agent harnesses (Claude Code, Codex) were found on PATH. Subtasks are left unassigned — install Claude Code and/or Codex to enable delegation.")
    case 1:
      notes.append("Only one agent harness was detected (\(detectedCLIs[0].provider.harnessName)); every subtask is assigned to it.")
    default:
      let names = detectedCLIs.map(\.provider.harnessName).joined(separator: ", ")
      notes.append("\(detectedCLIs.count) agent harnesses detected (\(names)). Each subtask is suggested the harness whose installed skills/MCP tools best fit — confirm or override using the capabilities below.")
    }

    for capability in capabilities {
      let parts = [
        capability.skills.isEmpty ? nil : "skills: \(capability.skills.map(\.name).joined(separator: ", "))",
        capability.mcpServers.isEmpty ? nil : "MCP: \(capability.mcpServers.joined(separator: ", "))",
      ].compactMap { $0 }
      if parts.isEmpty {
        notes.append("\(capability.provider.harnessName): no skills or MCP servers detected.")
      } else {
        notes.append("\(capability.provider.harnessName) — \(parts.joined(separator: "; ")).")
      }
    }

    notes.append("AgentHub launches the agent harness only; it cannot configure the model. Present the harness (Claude Code or Codex) for each subtask — never a model.")
    notes.append("This plan is advisory. If the user explicitly approves worktree creation, create one worktree per approved subtask with agenthub_create_worktree_sessions.")
    return notes
  }

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

  static func instructions(for subtask: Subtask, harness: String, branch: String) -> String {
    let focus = subtask.tags.map(\.displayName).joined(separator: ", ")
    return """
    Use \(harness). Work only on this subtask: \(subtask.detail)
    Branch: \(branch). Stay scoped to this subtask and avoid editing files owned by other parallel subtasks.
    Primary focus areas: \(focus).
    When done, ensure the change builds and its tests pass before handing off.
    """
  }

  /// Instructions for an assignment deferred to the calling agent: more than one
  /// harness is installed and nothing matched, so the agent picks itself.
  static func deferredInstructions(for subtask: Subtask, harnessNames: String, branch: String) -> String {
    let focus = subtask.tags.map(\.displayName).joined(separator: ", ")
    return """
    Choose the best installed agent harness (\(harnessNames)) for this subtask using the harness capabilities listed in the plan.
    Work only on this subtask: \(subtask.detail)
    Branch: \(branch). Stay scoped to this subtask and avoid editing files owned by other parallel subtasks.
    Primary focus areas: \(focus).
    When done, ensure the change builds and its tests pass before handing off.
    """
  }

  static func unassignedInstructions(for subtask: Subtask, branch: String) -> String {
    let focus = subtask.tags.map(\.displayName).joined(separator: ", ")
    return """
    No agent harness is installed — install Claude Code or Codex, then run this subtask.
    Work only on this subtask: \(subtask.detail)
    Branch: \(branch). Stay scoped to this subtask and avoid editing files owned by other parallel subtasks.
    Primary focus areas: \(focus).
    When done, ensure the change builds and its tests pass before handing off.
    """
  }
}
