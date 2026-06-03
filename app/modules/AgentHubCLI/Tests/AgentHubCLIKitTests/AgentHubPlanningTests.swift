import Foundation
import Testing

@testable import AgentHubCLIKit

// MARK: - CLI detection

@Suite("AgentCLIDetector")
struct AgentCLIDetectorTests {
  @Test("Detects both harnesses when both executables are on PATH")
  func detectsBoth() async {
    let detector = AgentCLIDetector(
      pathDirectories: ["/opt/bin", "/usr/local/bin"],
      isExecutable: { path in path == "/opt/bin/claude" || path == "/usr/local/bin/codex" }
    )
    let detected = await detector.detectInstalledCLIs()
    #expect(detected.map(\.provider) == [.claude, .codex])
  }

  @Test("Returns empty when nothing is installed")
  func detectsNone() async {
    let detector = AgentCLIDetector(pathDirectories: ["/usr/bin"], isExecutable: { _ in false })
    #expect(await detector.detectInstalledCLIs().isEmpty)
  }
}

// MARK: - Harness naming

@Suite("Harness naming")
struct HarnessNamingTests {
  @Test("Providers expose their harness name, never a model")
  func harnessNames() {
    #expect(WorktreeLaunchProvider.claude.harnessName == "Claude Code")
    #expect(WorktreeLaunchProvider.codex.harnessName == "Codex")
  }
}

// MARK: - Capability detection

@Suite("HarnessCapabilityDetector")
struct HarnessCapabilityDetectorTests {
  @Test("Detects Claude skills and MCP servers (top-level + project)")
  func detectsClaude() async throws {
    let home = Self.makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Self.writeSkill(home: home, provider: ".claude", slug: "swiftui-pro",
                        name: "swiftui-pro", description: "Reviews SwiftUI code for performance and best practices.")
    try Self.writeSkill(home: home, provider: ".claude", slug: "xcode-troubleshoot",
                        name: "xcode-troubleshoot", description: "Fix Xcode issues.")
    let claudeJSON = #"{"mcpServers": {"xctrace-analyzer": {}, "pencil": {}}, "projects": {"/repo": {"mcpServers": {"agenthub": {}}}}}"#
    try claudeJSON.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

    let caps = await HarnessCapabilityDetector(homeDirectory: home)
      .detectCapabilities(for: .claude, repositoryPath: "/repo")

    #expect(caps.skills.map(\.name) == ["swiftui-pro", "xcode-troubleshoot"])
    #expect(caps.skills.first?.description.contains("SwiftUI") == true)
    #expect(Set(caps.mcpServers) == ["xctrace-analyzer", "pencil", "agenthub"])
  }

  @Test("Detects Codex skills and MCP servers from config.toml (dedups sub-tables)")
  func detectsCodex() async throws {
    let home = Self.makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Self.writeSkill(home: home, provider: ".codex", slug: "figma-implement-design",
                        name: "figma-implement-design", description: "Implement Figma designs into code.")
    let toml = """
    [mcp_servers.xctrace-analyzer]
    command = "x"
    [mcp_servers.node_repl]
    command = "y"
    [mcp_servers.node_repl.env]
    FOO = "bar"
    """
    let codexDir = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    try toml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let caps = await HarnessCapabilityDetector(homeDirectory: home)
      .detectCapabilities(for: .codex, repositoryPath: nil)

    #expect(caps.skills.map(\.name) == ["figma-implement-design"])
    #expect(Set(caps.mcpServers) == ["xctrace-analyzer", "node_repl"])
  }

  @Test("Returns empty capabilities when nothing is installed")
  func detectsNothing() async {
    let home = Self.makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let caps = await HarnessCapabilityDetector(homeDirectory: home)
      .detectCapabilities(for: .claude, repositoryPath: nil)
    #expect(caps.isEmpty)
  }

  static func makeHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("HCD-\(UUID().uuidString)", isDirectory: true)
  }

  static func writeSkill(home: URL, provider: String, slug: String, name: String, description: String) throws {
    let dir = home.appendingPathComponent(provider).appendingPathComponent("skills").appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let markdown = """
    ---
    name: \(name)
    description: \(description)
    ---

    # \(name)
    """
    try markdown.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  }
}

// MARK: - End-to-end planning

@Suite("AgentHubPlanningService")
struct AgentHubPlanningServiceTests {
  @Test("Assigns every subtask to the only installed harness")
  func singleHarnessGetsEverything() async {
    let plan = await planner(claude).buildPlan(
      prompt: "Build the settings page",
      providedSubtasks: ["Build the settings page", "Write the migration"],
      repositoryPath: nil
    )
    #expect(plan.assignments.count == 2)
    #expect(plan.assignments.allSatisfy { $0.assignedProvider == .claude })
    #expect(plan.notes.contains { $0.contains("Only one agent harness") })
    #expect(!plan.assignments[0].rationale.lowercased().contains("opus"))
  }

  @Test("Suggests the harness whose real skills/MCP tools match the subtask")
  func suggestsByCapability() async {
    let planner = AgentHubPlanningService(
      detector: StubDetector(clis: [claude, codex]),
      capabilityDetector: StubCapabilityDetector(capabilities: [
        .claude: HarnessCapabilities(
          provider: .claude,
          skills: [HarnessSkill(name: "swiftui-pro", description: "Reviews SwiftUI code for performance.")],
          mcpServers: ["xctrace-analyzer"]
        ),
        .codex: HarnessCapabilities(
          provider: .codex,
          skills: [HarnessSkill(name: "figma-implement-design", description: "Implement Figma designs into code.")],
          mcpServers: []
        ),
      ])
    )
    let plan = await planner.buildPlan(
      prompt: "Plan",
      providedSubtasks: [
        "Build the SwiftUI settings screen",
        "Implement the Figma dashboard design",
      ],
      repositoryPath: nil
    )
    #expect(plan.assignments[0].assignedProvider == .claude)
    #expect(plan.assignments[0].matchedCapabilities.contains("swiftui-pro"))
    #expect(plan.assignments[1].assignedProvider == .codex)
    #expect(plan.assignments[1].matchedCapabilities.contains("figma-implement-design"))
    #expect(plan.harnessCapabilities.count == 2)
    // The suggestion cites the matching capability, not a model.
    #expect(plan.assignments[0].rationale.contains("swiftui-pro"))
  }

  @Test("Defers to the agent when no harness capability matches")
  func defersOnNoMatch() async {
    let planner = AgentHubPlanningService(
      detector: StubDetector(clis: [claude, codex]),
      capabilityDetector: StubCapabilityDetector(capabilities: [
        .claude: HarnessCapabilities(provider: .claude, skills: [HarnessSkill(name: "hatch-pet", description: "A pet hatching game.")], mcpServers: []),
        .codex: HarnessCapabilities(provider: .codex, skills: [HarnessSkill(name: "figma", description: "Figma design helper.")], mcpServers: []),
      ])
    )
    let plan = await planner.buildPlan(
      prompt: "Plan",
      providedSubtasks: ["Refactor the database access layer"],
      repositoryPath: nil
    )
    #expect(plan.assignments[0].assignedProvider == nil)
    #expect(plan.assignments[0].instructions.contains("Choose the best installed agent harness"))
  }

  @Test("Surfaces each harness's capabilities in the plan notes")
  func surfacesCapabilitiesInNotes() async {
    let planner = AgentHubPlanningService(
      detector: StubDetector(clis: [claude, codex]),
      capabilityDetector: StubCapabilityDetector(capabilities: [
        .claude: HarnessCapabilities(provider: .claude, skills: [HarnessSkill(name: "swiftui-pro", description: "x")], mcpServers: ["xctrace-analyzer"]),
        .codex: HarnessCapabilities(provider: .codex, skills: [], mcpServers: ["node_repl"]),
      ])
    )
    let plan = await planner.buildPlan(prompt: "Plan", providedSubtasks: ["Do a thing"], repositoryPath: nil)
    #expect(plan.notes.contains { $0.contains("Claude Code") && $0.contains("swiftui-pro") && $0.contains("xctrace-analyzer") })
    #expect(plan.notes.contains { $0.contains("never a model") })
  }

  @Test("Raw prose text is not statically split")
  func rawProseTextIsNotStaticallySplit() async {
    let prompt = "Build the React UI, refactor the API, and write tests; also update docs"
    let plan = await planner(claude).buildPlan(prompt: prompt, providedSubtasks: [], repositoryPath: nil)
    #expect(plan.assignments.count == 1)
    #expect(plan.assignments[0].subtask.detail == prompt)
  }

  @Test("A numbered prompt without provided subtasks stays a single task")
  func numberedPromptWithoutSubtasksIsSingleTask() async {
    let prompt = """
    1. Build the React UI
    2. Refactor the API and write tests
    """
    let plan = await planner(claude).buildPlan(prompt: prompt, providedSubtasks: [], repositoryPath: nil)
    #expect(plan.assignments.count == 1)
    #expect(plan.assignments[0].subtask.detail == prompt)
  }

  @Test("Leaves subtasks unassigned and notes the gap when no harness is installed")
  func noHarnessesInstalled() async {
    let planner = AgentHubPlanningService(
      detector: StubDetector(clis: []),
      capabilityDetector: StubCapabilityDetector(capabilities: [:])
    )
    let plan = await planner.buildPlan(prompt: "Fix the bug", providedSubtasks: [], repositoryPath: nil)
    #expect(plan.assignments.count == 1)
    #expect(plan.assignments[0].assignedProvider == nil)
    #expect(plan.detectedCLIs.isEmpty)
    #expect(plan.notes.contains { $0.contains("No agent harnesses") })
  }

  @Test("Provided subtasks are used verbatim (agent-inferred decomposition)")
  func providedSubtasksAreUsed() async {
    let plan = await planner(claude).buildPlan(
      prompt: "this prose would otherwise become one subtask",
      providedSubtasks: ["First explicit task", "Second explicit task", "Third explicit task"],
      repositoryPath: nil
    )
    #expect(plan.assignments.count == 3)
    #expect(plan.assignments[0].subtask.detail == "First explicit task")
  }

  @Test("Branch suggestions are unique when slug prefixes collide")
  func branchSuggestionsAreUniqueWhenSlugPrefixesCollide() async {
    let plan = await planner(claude).buildPlan(
      prompt: "Plan",
      providedSubtasks: [
        "Implement OAuth login callback flow for the API",
        "Implement OAuth login callback flow for the settings UI",
      ],
      repositoryPath: nil
    )
    let branches = plan.assignments.map(\.branchSuggestion)
    #expect(Set(branches).count == 2)
    #expect(branches[0] == "agent-implement-oauth-login-callback-flow")
    #expect(branches[1].hasPrefix("agent-implement-oauth-login-callback-flow-task-2"))
  }

  @Test("Untagged text defaults to the coding tag")
  func tagsDefaultToCoding() {
    #expect(AgentHubPlanningService.tags(for: "Something unrelated to keywords") == [.coding])
  }

  // MARK: helpers

  private let claude = DetectedAgentCLI(provider: .claude, executablePath: "/bin/claude")
  private let codex = DetectedAgentCLI(provider: .codex, executablePath: "/bin/codex")

  private func planner(_ clis: DetectedAgentCLI...) -> AgentHubPlanningService {
    AgentHubPlanningService(
      detector: StubDetector(clis: clis),
      capabilityDetector: StubCapabilityDetector(capabilities: [:])
    )
  }
}

// MARK: - Stubs

private struct StubDetector: AgentCLIDetecting {
  let clis: [DetectedAgentCLI]
  func detectInstalledCLIs() async -> [DetectedAgentCLI] { clis }
}

private struct StubCapabilityDetector: HarnessCapabilityDetecting {
  let capabilities: [WorktreeLaunchProvider: HarnessCapabilities]
  func detectCapabilities(for provider: WorktreeLaunchProvider, repositoryPath: String?) async -> HarnessCapabilities {
    capabilities[provider] ?? HarnessCapabilities(provider: provider, skills: [], mcpServers: [])
  }
}
