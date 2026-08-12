//
//  ProjectDetailsInventoryService.swift
//  AgentHub
//

import Foundation

// MARK: - Models

/// Where an agent asset (skill, MCP server, rule file) is configured.
public enum ProjectAssetScope: String, Sendable, CaseIterable, Codable {
  /// Configured inside the project repository.
  case project
  /// Configured in the user's home-level configuration (`~/.claude`, `~/.codex`, …).
  case personal
}

/// A skill discovered on disk, merged across providers when the same skill
/// name is installed for both Claude and Codex within the same scope.
public struct ProjectAgentSkill: Identifiable, Equatable, Sendable {
  public var id: String { "\(scope.rawValue)|\(name)" }
  public let name: String
  public let skillDescription: String
  public let scope: ProjectAssetScope
  public let providers: Set<SessionProviderKind>
  /// Files bundled beside SKILL.md (references, scripts, …).
  public let supportingFileCount: Int
  /// The skill's on-disk directory (contains SKILL.md).
  public let directoryPath: String

  public init(
    name: String,
    skillDescription: String,
    scope: ProjectAssetScope,
    providers: Set<SessionProviderKind>,
    supportingFileCount: Int = 0,
    directoryPath: String = ""
  ) {
    self.name = name
    self.skillDescription = skillDescription
    self.scope = scope
    self.providers = providers
    self.supportingFileCount = supportingFileCount
    self.directoryPath = directoryPath
  }
}

/// An MCP server entry, merged across providers when the same server name is
/// configured for both Claude and Codex within the same scope.
public struct ProjectMCPServerEntry: Identifiable, Equatable, Sendable {
  public var id: String { "\(scope.rawValue)|\(name)" }
  public let name: String
  /// Human-readable transport summary ("npx -y some-server", "https://…").
  public let detail: String
  public let scope: ProjectAssetScope
  public let providers: Set<SessionProviderKind>

  public init(
    name: String,
    detail: String,
    scope: ProjectAssetScope,
    providers: Set<SessionProviderKind>
  ) {
    self.name = name
    self.detail = detail
    self.scope = scope
    self.providers = providers
  }
}

/// A rules/instructions file (CLAUDE.md, AGENTS.md, Codex `.rules`).
public struct ProjectAgentRule: Identifiable, Equatable, Sendable {
  public var id: String { path }
  public let title: String
  public let path: String
  public let scope: ProjectAssetScope
  public let providers: Set<SessionProviderKind>
  public let preview: String
  public let lineCount: Int

  public init(
    title: String,
    path: String,
    scope: ProjectAssetScope,
    providers: Set<SessionProviderKind>,
    preview: String,
    lineCount: Int
  ) {
    self.title = title
    self.path = path
    self.scope = scope
    self.providers = providers
    self.preview = preview
    self.lineCount = lineCount
  }
}

/// Everything the Project Details panel shows besides sessions.
public struct ProjectDetailsInventory: Equatable, Sendable {
  public let skills: [ProjectAgentSkill]
  public let mcpServers: [ProjectMCPServerEntry]
  public let rules: [ProjectAgentRule]

  public init(
    skills: [ProjectAgentSkill] = [],
    mcpServers: [ProjectMCPServerEntry] = [],
    rules: [ProjectAgentRule] = []
  ) {
    self.skills = skills
    self.mcpServers = mcpServers
    self.rules = rules
  }

  public static let empty = ProjectDetailsInventory()
}

// MARK: - Service

public protocol ProjectDetailsInventoryServiceProtocol: Sendable {
  func inventory(forProjectAt projectPath: String) async -> ProjectDetailsInventory
}

/// Scans the standard Claude and Codex on-disk locations for skills, MCP
/// servers, and rules files relevant to a project:
/// - Skills: `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` and the
///   project-level `.claude/skills`, `.codex/skills`, `.agents/skills`.
/// - MCP servers: `~/.claude.json` (`mcpServers` + `projects[path].mcpServers`),
///   `{project}/.mcp.json`, and `~/.codex/config.toml` (`[mcp_servers.*]`).
/// - Rules: `CLAUDE.md` / `AGENTS.md` at personal and project scope, plus
///   `~/.codex/rules/*.rules`.
public actor ProjectDetailsInventoryService: ProjectDetailsInventoryServiceProtocol {
  public static let shared = ProjectDetailsInventoryService()

  private let homeDirectory: URL

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory
  }

  public func inventory(forProjectAt projectPath: String) async -> ProjectDetailsInventory {
    let home = homeDirectory
    return await Task.detached(priority: .utility) {
      Self.scan(projectPath: projectPath, homeDirectory: home)
    }.value
  }

  // MARK: - Scan (pure, synchronous — exercised directly by unit tests)

  nonisolated static func scan(projectPath: String, homeDirectory: URL) -> ProjectDetailsInventory {
    let projectURL = URL(fileURLWithPath: NSString(string: projectPath).expandingTildeInPath)
      .standardizedFileURL
    return ProjectDetailsInventory(
      skills: scanSkills(projectURL: projectURL, homeDirectory: homeDirectory),
      mcpServers: scanMCPServers(projectURL: projectURL, homeDirectory: homeDirectory),
      rules: scanRules(projectURL: projectURL, homeDirectory: homeDirectory)
    )
  }

  // MARK: - Skills

  private struct SkillSource {
    let root: URL
    let scope: ProjectAssetScope
    let providers: Set<SessionProviderKind>
  }

  private nonisolated static func scanSkills(
    projectURL: URL,
    homeDirectory: URL
  ) -> [ProjectAgentSkill] {
    let sources: [SkillSource] = [
      SkillSource(
        root: homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true),
        scope: .personal,
        providers: [.claude]
      ),
      SkillSource(
        root: homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true),
        scope: .personal,
        providers: [.codex]
      ),
      SkillSource(
        root: homeDirectory.appendingPathComponent(".agents/skills", isDirectory: true),
        scope: .personal,
        providers: [.claude, .codex]
      ),
      SkillSource(
        root: projectURL.appendingPathComponent(".claude/skills", isDirectory: true),
        scope: .project,
        providers: [.claude]
      ),
      SkillSource(
        root: projectURL.appendingPathComponent(".codex/skills", isDirectory: true),
        scope: .project,
        providers: [.codex]
      ),
      SkillSource(
        root: projectURL.appendingPathComponent(".agents/skills", isDirectory: true),
        scope: .project,
        providers: [.claude, .codex]
      )
    ]

    var merged: [String: ProjectAgentSkill] = [:]
    for source in sources {
      for skill in skills(inRoot: source.root, scope: source.scope, providers: source.providers) {
        if let existing = merged[skill.id] {
          merged[skill.id] = ProjectAgentSkill(
            name: existing.name,
            skillDescription: existing.skillDescription.isEmpty
              ? skill.skillDescription
              : existing.skillDescription,
            scope: existing.scope,
            providers: existing.providers.union(skill.providers),
            supportingFileCount: max(existing.supportingFileCount, skill.supportingFileCount),
            directoryPath: existing.directoryPath.isEmpty
              ? skill.directoryPath
              : existing.directoryPath
          )
        } else {
          merged[skill.id] = skill
        }
      }
    }
    return merged.values.sorted {
      $0.name == $1.name ? $0.scope.rawValue < $1.scope.rawValue : $0.name < $1.name
    }
  }

  private nonisolated static func skills(
    inRoot root: URL,
    scope: ProjectAssetScope,
    providers: Set<SessionProviderKind>
  ) -> [ProjectAgentSkill] {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) else {
      return []
    }

    return entries.compactMap { directory -> ProjectAgentSkill? in
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
        return nil
      }
      let skillFile = directory.appendingPathComponent("SKILL.md", isDirectory: false)
      guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else {
        return nil
      }
      let parsed = parseFrontmatter(content)
      return ProjectAgentSkill(
        name: parsed.name ?? directory.lastPathComponent,
        skillDescription: parsed.description ?? "",
        scope: scope,
        providers: providers,
        supportingFileCount: supportingFileCount(in: directory),
        directoryPath: directory.path
      )
    }
  }

  /// Files inside the skill directory other than SKILL.md itself.
  private nonisolated static func supportingFileCount(in directory: URL) -> Int {
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
      return 0
    }
    var count = 0
    for case let file as URL in enumerator {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
        continue
      }
      if file.lastPathComponent == "SKILL.md",
         file.deletingLastPathComponent().path == directory.path {
        continue
      }
      count += 1
    }
    return count
  }

  /// Extracts `name`/`description` from a SKILL.md YAML frontmatter block.
  nonisolated static func parseFrontmatter(_ content: String) -> (name: String?, description: String?) {
    let lines = content.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
      return (nil, nil)
    }
    var name: String?
    var description: String?
    for line in lines.dropFirst() {
      if line.trimmingCharacters(in: .whitespaces) == "---" { break }
      if name == nil, let value = frontmatterValue(of: "name", in: line) { name = value }
      if description == nil, let value = frontmatterValue(of: "description", in: line) {
        description = value
      }
    }
    return (name, description)
  }

  private nonisolated static func frontmatterValue(of key: String, in line: String) -> String? {
    guard line.lowercased().hasPrefix("\(key):") else { return nil }
    let afterColon = line.drop { $0 != ":" }.dropFirst()
    let value = afterColon
      .trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return value.isEmpty ? nil : value
  }

  // MARK: - MCP servers

  private nonisolated static func scanMCPServers(
    projectURL: URL,
    homeDirectory: URL
  ) -> [ProjectMCPServerEntry] {
    var merged: [String: ProjectMCPServerEntry] = [:]

    func add(_ entry: ProjectMCPServerEntry) {
      if let existing = merged[entry.id] {
        merged[entry.id] = ProjectMCPServerEntry(
          name: existing.name,
          detail: existing.detail.isEmpty ? entry.detail : existing.detail,
          scope: existing.scope,
          providers: existing.providers.union(entry.providers)
        )
      } else {
        merged[entry.id] = entry
      }
    }

    // Claude: ~/.claude.json holds global servers plus per-project overrides
    // keyed by absolute project path.
    let claudeConfigURL = homeDirectory.appendingPathComponent(".claude.json", isDirectory: false)
    if let data = try? Data(contentsOf: claudeConfigURL),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let global = root["mcpServers"] as? [String: Any] {
        for entry in claudeEntries(global, scope: .personal) { add(entry) }
      }
      if let projects = root["projects"] as? [String: Any],
         let project = projects[projectURL.path] as? [String: Any],
         let projectServers = project["mcpServers"] as? [String: Any] {
        for entry in claudeEntries(projectServers, scope: .project) { add(entry) }
      }
    }

    // Claude: repo-local .mcp.json (shared, checked-in project servers).
    let mcpJSONURL = projectURL.appendingPathComponent(".mcp.json", isDirectory: false)
    if let data = try? Data(contentsOf: mcpJSONURL),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let servers = root["mcpServers"] as? [String: Any] {
      for entry in claudeEntries(servers, scope: .project) { add(entry) }
    }

    // Codex: ~/.codex/config.toml [mcp_servers.<name>] tables.
    let codexConfigURL = homeDirectory.appendingPathComponent(".codex/config.toml", isDirectory: false)
    if let content = try? String(contentsOf: codexConfigURL, encoding: .utf8) {
      for entry in codexEntries(fromTOML: content) { add(entry) }
    }

    return merged.values.sorted {
      $0.name == $1.name ? $0.scope.rawValue < $1.scope.rawValue : $0.name < $1.name
    }
  }

  private nonisolated static func claudeEntries(
    _ rawServers: [String: Any],
    scope: ProjectAssetScope
  ) -> [ProjectMCPServerEntry] {
    rawServers.compactMap { name, value in
      guard let dictionary = value as? [String: Any] else { return nil }
      return ProjectMCPServerEntry(
        name: name,
        detail: serverDetail(command: dictionary["command"] as? String,
                             args: dictionary["args"] as? [String] ?? [],
                             url: dictionary["url"] as? String),
        scope: scope,
        providers: [.claude]
      )
    }
  }

  private nonisolated static func codexEntries(fromTOML content: String) -> [ProjectMCPServerEntry] {
    var commands: [String: String] = [:]
    var args: [String: [String]] = [:]
    var urls: [String: String] = [:]
    var order: [String] = []
    var currentServer: String?

    for rawLine in content.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }

      if line.hasPrefix("["), line.hasSuffix("]") {
        let table = String(line.dropFirst().dropLast())
        guard table.hasPrefix("mcp_servers.") else {
          currentServer = nil
          continue
        }
        let suffix = String(table.dropFirst("mcp_servers.".count))
        let name = (suffix.split(separator: ".").first.map(String.init) ?? "")
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !name.isEmpty else {
          currentServer = nil
          continue
        }
        // Sub-tables like [mcp_servers.<name>.env] keep contributing to <name>,
        // but their keys are not transport details we surface.
        currentServer = suffix.contains(".") ? nil : name
        if !order.contains(name) { order.append(name) }
        continue
      }

      guard let currentServer, let equals = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
      let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
      switch key {
      case "command":
        commands[currentServer] = tomlString(rawValue)
      case "args":
        args[currentServer] = tomlStringArray(rawValue)
      case "url":
        urls[currentServer] = tomlString(rawValue)
      default:
        break
      }
    }

    return order.map { name in
      ProjectMCPServerEntry(
        name: name,
        detail: serverDetail(command: commands[name], args: args[name] ?? [], url: urls[name]),
        scope: .personal,
        providers: [.codex]
      )
    }
  }

  private nonisolated static func serverDetail(
    command: String?,
    args: [String],
    url: String?
  ) -> String {
    if let url, !url.isEmpty { return url }
    guard let command, !command.isEmpty else { return "" }
    return ([command] + args).joined(separator: " ")
  }

  private nonisolated static func tomlString(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2 else { return nil }
    if (trimmed.first == "\"" && trimmed.last == "\"") ||
       (trimmed.first == "'" && trimmed.last == "'") {
      return String(trimmed.dropFirst().dropLast())
        .replacingOccurrences(of: "\\\"", with: "\"")
    }
    return nil
  }

  private nonisolated static func tomlStringArray(_ value: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #""([^"\\]|\\.)*"|'[^']*'"#) else {
      return []
    }
    let range = NSRange(value.startIndex..., in: value)
    return regex.matches(in: value, range: range).compactMap { match in
      guard let matchRange = Range(match.range, in: value) else { return nil }
      return tomlString(String(value[matchRange]))
    }
  }

  // MARK: - Rules

  private nonisolated static func scanRules(
    projectURL: URL,
    homeDirectory: URL
  ) -> [ProjectAgentRule] {
    var rules: [ProjectAgentRule] = []

    func addFile(
      _ url: URL,
      scope: ProjectAssetScope,
      providers: Set<SessionProviderKind>
    ) {
      guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
      rules.append(ProjectAgentRule(
        title: url.lastPathComponent,
        path: url.path,
        scope: scope,
        providers: providers,
        preview: rulePreview(content),
        lineCount: content.components(separatedBy: .newlines).count
      ))
    }

    addFile(
      homeDirectory.appendingPathComponent(".claude/CLAUDE.md", isDirectory: false),
      scope: .personal,
      providers: [.claude]
    )
    addFile(
      homeDirectory.appendingPathComponent(".codex/AGENTS.md", isDirectory: false),
      scope: .personal,
      providers: [.codex]
    )
    addFile(
      projectURL.appendingPathComponent("CLAUDE.md", isDirectory: false),
      scope: .project,
      providers: [.claude]
    )
    addFile(
      projectURL.appendingPathComponent(".claude/CLAUDE.md", isDirectory: false),
      scope: .project,
      providers: [.claude]
    )
    addFile(
      projectURL.appendingPathComponent("AGENTS.md", isDirectory: false),
      scope: .project,
      providers: [.codex]
    )

    // Codex prefix rules (~/.codex/rules/*.rules).
    let codexRulesRoot = homeDirectory.appendingPathComponent(".codex/rules", isDirectory: true)
    if let entries = try? FileManager.default.contentsOfDirectory(
      at: codexRulesRoot,
      includingPropertiesForKeys: nil
    ) {
      for file in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      where file.pathExtension == "rules" {
        addFile(file, scope: .personal, providers: [.codex])
      }
    }

    return rules
  }

  private nonisolated static func rulePreview(_ content: String) -> String {
    let lines = content
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && $0 != "---" }
    return lines.prefix(3).joined(separator: "\n").prefix(220).description
  }
}
