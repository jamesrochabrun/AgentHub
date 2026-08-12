import Foundation
import Testing

@testable import AgentHubCore

@Suite("Project details inventory")
struct ProjectDetailsInventoryServiceTests {

  // MARK: - Fixture

  /// Builds a fake home directory + project directory tree, runs the scan,
  /// and tears everything down.
  private func withFixture(
    _ body: (_ home: URL, _ project: URL) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("project-details-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(home, project)
  }

  private func writeFile(_ url: URL, _ content: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  private func writeSkill(
    root: URL,
    directory: String,
    name: String?,
    description: String
  ) throws {
    var frontmatter = "---\n"
    if let name {
      frontmatter += "name: \(name)\n"
    }
    frontmatter += "description: \(description)\n---\n\n# Skill\n"
    try writeFile(
      root.appendingPathComponent("\(directory)/SKILL.md", isDirectory: false),
      frontmatter
    )
  }

  private func scan(home: URL, project: URL) -> ProjectDetailsInventory {
    ProjectDetailsInventoryService.scan(projectPath: project.path, homeDirectory: home)
  }

  // MARK: - Skills

  @Test("Same-named skill in Claude and Codex personal dirs merges into one entry with both providers")
  func personalSkillMergesAcrossProviders() throws {
    try withFixture { home, project in
      try writeSkill(
        root: home.appendingPathComponent(".claude/skills"),
        directory: "swiftui-animation",
        name: "swiftui-animation",
        description: "Animations"
      )
      try writeSkill(
        root: home.appendingPathComponent(".codex/skills"),
        directory: "swiftui-animation",
        name: "swiftui-animation",
        description: "Animations"
      )
      try writeSkill(
        root: home.appendingPathComponent(".codex/skills"),
        directory: "codex-only",
        name: "codex-only",
        description: "Codex thing"
      )

      let inventory = scan(home: home, project: project)

      #expect(inventory.skills.count == 2)
      let merged = try #require(inventory.skills.first { $0.name == "swiftui-animation" })
      #expect(merged.providers == [.claude, .codex])
      #expect(merged.scope == .personal)
      #expect(merged.directoryPath.hasSuffix(".claude/skills/swiftui-animation"))
      let codexOnly = try #require(inventory.skills.first { $0.name == "codex-only" })
      #expect(codexOnly.providers == [.codex])
    }
  }

  @Test("Project skills keep their own scope and don't merge with same-named personal skills")
  func projectScopeStaysDistinctFromPersonal() throws {
    try withFixture { home, project in
      try writeSkill(
        root: home.appendingPathComponent(".claude/skills"),
        directory: "deploy",
        name: "deploy",
        description: "Personal deploy"
      )
      try writeSkill(
        root: project.appendingPathComponent(".claude/skills"),
        directory: "deploy",
        name: "deploy",
        description: "Project deploy"
      )

      let inventory = scan(home: home, project: project)

      #expect(inventory.skills.count == 2)
      let scopes = Set(inventory.skills.map(\.scope))
      #expect(scopes == [.personal, .project])
    }
  }

  @Test("Skills in .agents/skills are marked available to both providers")
  func agentsDirectorySkillsCoverBothProviders() throws {
    try withFixture { home, project in
      try writeSkill(
        root: project.appendingPathComponent(".agents/skills"),
        directory: "shared",
        name: "shared",
        description: "Shared"
      )

      let inventory = scan(home: home, project: project)

      let skill = try #require(inventory.skills.first)
      #expect(skill.providers == [.claude, .codex])
      #expect(skill.scope == .project)
    }
  }

  @Test("Skill name falls back to directory name and supporting files are counted")
  func skillNameFallbackAndSupportingFiles() throws {
    try withFixture { home, project in
      let skillsRoot = home.appendingPathComponent(".claude/skills")
      try writeSkill(root: skillsRoot, directory: "no-name", name: nil, description: "Desc")
      try writeFile(
        skillsRoot.appendingPathComponent("no-name/references/guide.md"),
        "# Guide"
      )
      try writeFile(
        skillsRoot.appendingPathComponent("no-name/scripts/run.sh"),
        "echo hi"
      )

      let inventory = scan(home: home, project: project)

      let skill = try #require(inventory.skills.first)
      #expect(skill.name == "no-name")
      #expect(skill.skillDescription == "Desc")
      #expect(skill.supportingFileCount == 2)
    }
  }

  // MARK: - MCP servers

  @Test("Claude global, Claude project, .mcp.json, and Codex servers land in the right scopes")
  func mcpServerScopes() throws {
    try withFixture { home, project in
      let normalizedProjectPath = URL(fileURLWithPath: project.path).standardizedFileURL.path
      let claudeJSON = """
      {
        "mcpServers": {
          "figma": { "command": "npx", "args": ["-y", "figma-mcp"] }
        },
        "projects": {
          "\(normalizedProjectPath)": {
            "mcpServers": {
              "proj-server": { "command": "node", "args": ["server.js"] }
            }
          }
        }
      }
      """
      try writeFile(home.appendingPathComponent(".claude.json"), claudeJSON)
      try writeFile(
        project.appendingPathComponent(".mcp.json"),
        #"{ "mcpServers": { "shared": { "url": "https://example.com/mcp" } } }"#
      )
      try writeFile(
        home.appendingPathComponent(".codex/config.toml"),
        """
        model = "gpt-5"

        [mcp_servers.xctrace]
        command = "uvx"
        args = ["xctrace-mcp"]

        [mcp_servers.xctrace.env]
        KEY = "value"
        """
      )

      let inventory = scan(home: home, project: project)

      #expect(inventory.mcpServers.count == 4)

      let figma = try #require(inventory.mcpServers.first { $0.name == "figma" })
      #expect(figma.scope == .personal)
      #expect(figma.providers == [.claude])
      #expect(figma.detail == "npx -y figma-mcp")

      let projServer = try #require(inventory.mcpServers.first { $0.name == "proj-server" })
      #expect(projServer.scope == .project)

      let shared = try #require(inventory.mcpServers.first { $0.name == "shared" })
      #expect(shared.scope == .project)
      #expect(shared.detail == "https://example.com/mcp")

      let xctrace = try #require(inventory.mcpServers.first { $0.name == "xctrace" })
      #expect(xctrace.scope == .personal)
      #expect(xctrace.providers == [.codex])
      #expect(xctrace.detail == "uvx xctrace-mcp")
    }
  }

  @Test("Same-named personal server configured for Claude and Codex merges providers")
  func mcpServerMergesAcrossProviders() throws {
    try withFixture { home, project in
      try writeFile(
        home.appendingPathComponent(".claude.json"),
        #"{ "mcpServers": { "excalidraw": { "command": "npx", "args": ["excalidraw-mcp"] } } }"#
      )
      try writeFile(
        home.appendingPathComponent(".codex/config.toml"),
        """
        [mcp_servers.excalidraw]
        command = "npx"
        args = ["excalidraw-mcp"]
        """
      )

      let inventory = scan(home: home, project: project)

      #expect(inventory.mcpServers.count == 1)
      let merged = try #require(inventory.mcpServers.first)
      #expect(merged.providers == [.claude, .codex])
    }
  }

  // MARK: - Rules

  @Test("Rules files are collected with the right scope and provider")
  func rulesCollection() throws {
    try withFixture { home, project in
      try writeFile(
        home.appendingPathComponent(".claude/CLAUDE.md"),
        "# Personal rules\n\n- Use spaces\n"
      )
      try writeFile(
        home.appendingPathComponent(".codex/AGENTS.md"),
        "# Codex personal\n"
      )
      try writeFile(
        project.appendingPathComponent("CLAUDE.md"),
        "# Project rules\n\nDetails here.\n"
      )
      try writeFile(
        project.appendingPathComponent("AGENTS.md"),
        "# Project agents\n"
      )
      try writeFile(
        home.appendingPathComponent(".codex/rules/default.rules"),
        "prefix_rule(pattern=[\"git\"], decision=\"allow\")\n"
      )

      let inventory = scan(home: home, project: project)

      #expect(inventory.rules.count == 5)

      let personalClaude = try #require(
        inventory.rules.first { $0.title == "CLAUDE.md" && $0.scope == .personal }
      )
      #expect(personalClaude.providers == [.claude])
      #expect(personalClaude.preview.contains("# Personal rules"))
      #expect(personalClaude.lineCount > 1)

      let projectClaude = try #require(
        inventory.rules.first { $0.title == "CLAUDE.md" && $0.scope == .project }
      )
      #expect(projectClaude.preview.contains("# Project rules"))

      let codexRules = try #require(inventory.rules.first { $0.title == "default.rules" })
      #expect(codexRules.scope == .personal)
      #expect(codexRules.providers == [.codex])

      let projectAgents = try #require(
        inventory.rules.first { $0.title == "AGENTS.md" && $0.scope == .project }
      )
      #expect(projectAgents.providers == [.codex])
    }
  }

  @Test("Missing directories and files produce an empty inventory without errors")
  func missingEverythingIsEmpty() throws {
    try withFixture { home, project in
      let inventory = scan(home: home, project: project)
      #expect(inventory == .empty)
    }
  }

  // MARK: - Actor service

  @Test("Actor service scans through the injected home directory")
  func actorServiceUsesInjectedHome() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("project-details-actor-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try writeSkill(
      root: home.appendingPathComponent(".claude/skills"),
      directory: "only-skill",
      name: "only-skill",
      description: "The one"
    )

    let service = ProjectDetailsInventoryService(homeDirectory: home)
    let inventory = await service.inventory(forProjectAt: project.path)

    #expect(inventory.skills.map(\.name) == ["only-skill"])
  }
}

// MARK: - ProjectDetailsViewModel

private final class MockInventoryService: ProjectDetailsInventoryServiceProtocol, @unchecked Sendable {
  let result: ProjectDetailsInventory
  init(result: ProjectDetailsInventory) {
    self.result = result
  }

  func inventory(forProjectAt projectPath: String) async -> ProjectDetailsInventory {
    result
  }
}

@Suite("Project details view model")
@MainActor
struct ProjectDetailsViewModelTests {

  @Test("Load publishes the scanned inventory and clears the loading flag")
  func loadPublishesInventory() async {
    let expected = ProjectDetailsInventory(
      skills: [
        ProjectAgentSkill(
          name: "s",
          skillDescription: "d",
          scope: .personal,
          providers: [.claude]
        )
      ],
      mcpServers: [
        ProjectMCPServerEntry(name: "m", detail: "npx m", scope: .project, providers: [.codex])
      ],
      rules: []
    )
    let viewModel = ProjectDetailsViewModel(
      projectPath: "/tmp/some-project",
      service: MockInventoryService(result: expected)
    )

    #expect(viewModel.inventory == .empty)
    await viewModel.load()

    #expect(viewModel.inventory == expected)
    #expect(viewModel.isLoading == false)
  }
}
