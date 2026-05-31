import Foundation
import Testing

@testable import AgentHubCLIKit

// MARK: - Task decomposition

@Suite("HeuristicTaskDecomposer")
struct HeuristicTaskDecomposerTests {
  let decomposer = HeuristicTaskDecomposer()

  @Test("Splits a numbered list into one subtask per item")
  func splitsNumberedList() {
    let prompt = """
    Please do the following:
    1. Add a REST endpoint for users
    2. Build the React settings page
    3. Refactor the database access layer
    """
    let subtasks = decomposer.decompose(prompt: prompt)
    #expect(subtasks.count == 3)
    #expect(subtasks[0].id == "task-1")
    #expect(subtasks[0].detail == "Add a REST endpoint for users")
    #expect(subtasks[2].detail == "Refactor the database access layer")
  }

  @Test("Splits a bulleted list into discrete subtasks")
  func splitsBulletedList() {
    let prompt = """
    - Write unit tests for the parser
    - Document the public API
    """
    let subtasks = decomposer.decompose(prompt: prompt)
    #expect(subtasks.count == 2)
    #expect(subtasks[0].tags.contains(.testing))
    #expect(subtasks[1].tags.contains(.documentation))
  }

  @Test("Splits prose on conjunctions when there is no list")
  func splitsProse() {
    let prompt = "Implement the login API and then write tests for it; also update the README"
    let subtasks = decomposer.decompose(prompt: prompt)
    #expect(subtasks.count == 3)
  }

  @Test("A single instruction yields exactly one subtask")
  func singleInstruction() {
    let subtasks = decomposer.decompose(prompt: "Fix the crash in the settings screen")
    #expect(subtasks.count == 1)
    #expect(subtasks[0].tags.contains(.debugging))
  }

  @Test("Empty prompt yields no subtasks")
  func emptyPrompt() {
    #expect(decomposer.decompose(prompt: "   \n  ").isEmpty)
  }

  @Test("Untagged text defaults to the coding tag")
  func defaultsToCoding() {
    let tags = HeuristicTaskDecomposer.tags(for: "Something unrelated to keywords")
    #expect(tags == [.coding])
  }
}

// MARK: - CLI detection

@Suite("AgentCLIDetector")
struct AgentCLIDetectorTests {
  @Test("Detects both CLIs when both executables are on PATH")
  func detectsBoth() async {
    let detector = AgentCLIDetector(
      pathDirectories: ["/opt/bin", "/usr/local/bin"],
      isExecutable: { path in path == "/opt/bin/claude" || path == "/usr/local/bin/codex" }
    )
    let detected = await detector.detectInstalledCLIs()
    #expect(detected.map(\.provider) == [.claude, .codex])
    #expect(detected.first { $0.provider == .claude }?.executablePath == "/opt/bin/claude")
  }

  @Test("Detects only the installed CLI")
  func detectsOne() async {
    let detector = AgentCLIDetector(
      pathDirectories: ["/usr/bin"],
      isExecutable: { $0 == "/usr/bin/claude" }
    )
    let detected = await detector.detectInstalledCLIs()
    #expect(detected.map(\.provider) == [.claude])
  }

  @Test("Returns empty when nothing is installed")
  func detectsNone() async {
    let detector = AgentCLIDetector(pathDirectories: ["/usr/bin"], isExecutable: { _ in false })
    let detected = await detector.detectInstalledCLIs()
    #expect(detected.isEmpty)
  }
}

// MARK: - Capability research

@Suite("WebModelCapabilityResearchService")
struct WebModelCapabilityResearchServiceTests {
  @Test("Derives strengths and model from a web search result")
  func parsesWebResult() async {
    let html = """
    <div class="result">
      <a class="result__snippet" href="https://docs.example.com">
        Claude Opus 4.8 excels at coding, large refactoring, and debugging across an entire codebase.
      </a>
    </div>
    """
    let service = WebModelCapabilityResearchService(fetcher: StubFetcher(result: .success(html)))
    let profile = await service.researchCapabilities(for: .claude)

    #expect(profile.sourcedFromWeb)
    #expect(profile.model == "Claude Opus 4.8")
    #expect(profile.strengths.contains(.coding))
    #expect(profile.strengths.contains(.refactoring))
    #expect(profile.strengths.contains(.debugging))
    #expect(profile.sourceURL?.contains("duckduckgo.com") == true)
  }

  @Test("Falls back to the curated profile when the network fails")
  func fallsBackOnFailure() async {
    let service = WebModelCapabilityResearchService(fetcher: StubFetcher(result: .failure(StubError.offline)))
    let profile = await service.researchCapabilities(for: .codex)

    #expect(!profile.sourcedFromWeb)
    #expect(profile.model == "GPT-5.5")
    #expect(profile.sourceURL == nil)
    #expect(!profile.strengths.isEmpty)
  }

  @Test("Falls back when the page has no parseable snippet")
  func fallsBackOnEmptySnippet() async {
    let service = WebModelCapabilityResearchService(fetcher: StubFetcher(result: .success("<html><body>no results</body></html>")))
    let profile = await service.researchCapabilities(for: .claude)
    #expect(!profile.sourcedFromWeb)
    #expect(profile.model == "Claude Opus 4.8")
  }
}

// MARK: - End-to-end planning

@Suite("AgentHubPlanningService")
struct AgentHubPlanningServiceTests {
  @Test("Matches each subtask to the best-suited installed agent")
  func matchesSubtasksToAgents() async {
    let planner = AgentHubPlanningService(
      detector: StubDetector(clis: [
        DetectedAgentCLI(provider: .claude, executablePath: "/bin/claude"),
        DetectedAgentCLI(provider: .codex, executablePath: "/bin/codex"),
      ]),
      research: StubResearch(profiles: [
        .claude: profile(.claude, "Claude Opus 4.8", [.coding, .refactoring, .debugging, .reasoning, .longContext, .testing]),
        .codex: profile(.codex, "GPT-5.5", [.frontend, .dataAnalysis, .research, .reasoning, .coding, .documentation]),
      ])
    )

    let plan = await planner.buildPlan(
      prompt: """
      1. Build the React UI component for the dashboard
      2. Refactor and debug the authentication module
      """,
      providedSubtasks: [],
      repositoryPath: "/repo"
    )

    #expect(plan.assignments.count == 2)
    #expect(plan.assignments[0].assignedProvider == .codex)
    #expect(plan.assignments[1].assignedProvider == .claude)
    #expect(plan.assignments[1].matchedStrengths.contains(.refactoring))
    #expect(plan.modelProfiles.count == 2)
    #expect(plan.assignments[0].branchSuggestion.hasPrefix("agent-"))
    #expect(plan.assignments[0].instructions.contains("React UI component"))
  }

  @Test("Assigns everything to the only installed agent")
  func singleAgentGetsEverything() async {
    let planner = AgentHubPlanningService(
      detector: StubDetector(clis: [DetectedAgentCLI(provider: .claude, executablePath: "/bin/claude")]),
      research: StubResearch(profiles: [
        .claude: profile(.claude, "Claude Opus 4.8", [.coding, .refactoring]),
      ])
    )
    let plan = await planner.buildPlan(
      prompt: "Build the React UI; analyze the dataset",
      providedSubtasks: [],
      repositoryPath: nil
    )
    #expect(plan.assignments.allSatisfy { $0.assignedProvider == .claude })
    #expect(plan.notes.contains { $0.contains("Only one agent CLI") })
  }

  @Test("Leaves subtasks unassigned and notes the gap when no CLI is installed")
  func noAgentsInstalled() async {
    let planner = AgentHubPlanningService(
      detector: StubDetector(clis: []),
      research: StubResearch(profiles: [:])
    )
    let plan = await planner.buildPlan(
      prompt: "Fix the bug",
      providedSubtasks: [],
      repositoryPath: nil
    )
    #expect(plan.assignments.count == 1)
    #expect(plan.assignments[0].assignedProvider == nil)
    #expect(plan.detectedCLIs.isEmpty)
    #expect(plan.notes.contains { $0.contains("No agent CLIs") })
  }

  @Test("Provided subtasks override automatic decomposition")
  func providedSubtasksOverride() async {
    let planner = AgentHubPlanningService(
      detector: StubDetector(clis: [DetectedAgentCLI(provider: .claude, executablePath: "/bin/claude")]),
      research: StubResearch(profiles: [.claude: profile(.claude, "Claude Opus 4.8", [.coding])])
    )
    let plan = await planner.buildPlan(
      prompt: "this prose would otherwise become one subtask",
      providedSubtasks: ["First explicit task", "Second explicit task", "Third explicit task"],
      repositoryPath: nil
    )
    #expect(plan.assignments.count == 3)
    #expect(plan.assignments[0].subtask.detail == "First explicit task")
  }

  private func profile(
    _ provider: WorktreeLaunchProvider,
    _ model: String,
    _ strengths: [CapabilityTag]
  ) -> ModelCapabilityProfile {
    ModelCapabilityProfile(
      provider: provider,
      model: model,
      strengths: strengths,
      summary: "stub",
      sourceURL: nil,
      sourcedFromWeb: false
    )
  }
}

// MARK: - Stubs

private enum StubError: Error { case offline }

private struct StubFetcher: WebPageFetching {
  let result: Result<String, Error>
  func fetchText(from url: URL) async throws -> String {
    try result.get()
  }
}

private struct StubDetector: AgentCLIDetecting {
  let clis: [DetectedAgentCLI]
  func detectInstalledCLIs() async -> [DetectedAgentCLI] { clis }
}

private struct StubResearch: ModelCapabilityResearching {
  let profiles: [WorktreeLaunchProvider: ModelCapabilityProfile]
  func researchCapabilities(for provider: WorktreeLaunchProvider) async -> ModelCapabilityProfile {
    profiles[provider] ?? ModelCapabilityProfile(
      provider: provider,
      model: provider.rawValue,
      strengths: [.coding],
      summary: "stub",
      sourceURL: nil,
      sourcedFromWeb: false
    )
  }
}
