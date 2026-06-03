import Foundation

/// Detects what a harness can actually do right now — its installed skills and
/// configured MCP servers — so the planner can ground harness assignment in real
/// tooling instead of the harness's general reputation.
public protocol HarnessCapabilityDetecting: Sendable {
  func detectCapabilities(
    for provider: WorktreeLaunchProvider,
    repositoryPath: String?
  ) async -> HarnessCapabilities
}

/// Reads capabilities from each harness's standard on-disk locations:
/// - Skills: `~/.claude/skills/<name>/SKILL.md` and `~/.codex/skills/<name>/SKILL.md`.
/// - MCP servers: Claude `~/.claude.json` (`mcpServers`, plus the current
///   project's entry); Codex `~/.codex/config.toml` (`[mcp_servers.<name>]`).
public struct HarnessCapabilityDetector: HarnessCapabilityDetecting {
  /// Skill descriptions are capped to keep the plan compact while preserving
  /// enough signal to match against a subtask.
  private static let descriptionLimit = 240

  private let homeDirectory: URL

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory
  }

  public func detectCapabilities(
    for provider: WorktreeLaunchProvider,
    repositoryPath: String?
  ) async -> HarnessCapabilities {
    let providerDirectory = provider == .claude ? ".claude" : ".codex"
    let skills = detectSkills(providerDirectory: providerDirectory)
    let mcpServers: [String]
    switch provider {
    case .claude: mcpServers = detectClaudeMCPServers(repositoryPath: repositoryPath)
    case .codex: mcpServers = detectCodexMCPServers()
    }
    return HarnessCapabilities(provider: provider, skills: skills, mcpServers: mcpServers)
  }

  // MARK: - Skills

  func detectSkills(providerDirectory: String) -> [HarnessSkill] {
    let fileManager = FileManager.default
    let skillsRoot = homeDirectory
      .appendingPathComponent(providerDirectory, isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
    guard let entries = try? fileManager.contentsOfDirectory(
      at: skillsRoot,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) else {
      return []
    }

    return entries.compactMap { directory -> HarnessSkill? in
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
        return nil
      }
      let skillFile = directory.appendingPathComponent("SKILL.md", isDirectory: false)
      guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else {
        return nil
      }
      let parsed = Self.parseFrontmatter(content)
      let name = parsed.name ?? directory.lastPathComponent
      let description = (parsed.description ?? "").prefix(Self.descriptionLimit)
      return HarnessSkill(name: name, description: String(description))
    }
    .sorted { $0.name < $1.name }
  }

  /// Extracts `name`/`description` from a SKILL.md YAML frontmatter block.
  static func parseFrontmatter(_ content: String) -> (name: String?, description: String?) {
    let lines = content.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
      return (nil, nil)
    }
    var name: String?
    var description: String?
    for line in lines.dropFirst() {
      if line.trimmingCharacters(in: .whitespaces) == "---" { break }
      if name == nil, let value = frontmatterValue(of: "name", in: line) { name = value }
      if description == nil, let value = frontmatterValue(of: "description", in: line) { description = value }
    }
    return (name, description)
  }

  static func frontmatterValue(of key: String, in line: String) -> String? {
    guard line.lowercased().hasPrefix("\(key):") else { return nil }
    let afterColon = line.drop { $0 != ":" }.dropFirst()
    let value = afterColon
      .trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return value.isEmpty ? nil : value
  }

  // MARK: - Claude MCP servers (~/.claude.json)

  func detectClaudeMCPServers(repositoryPath: String?) -> [String] {
    let url = homeDirectory.appendingPathComponent(".claude.json", isDirectory: false)
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }

    var names = Set<String>()
    if let top = root["mcpServers"] as? [String: Any] {
      names.formUnion(top.keys)
    }
    // `~/.claude.json` keys per-project config by absolute repository path.
    if let repositoryPath,
       let projects = root["projects"] as? [String: Any],
       let project = projects[repositoryPath] as? [String: Any],
       let projectMCP = project["mcpServers"] as? [String: Any] {
      names.formUnion(projectMCP.keys)
    }
    return names.sorted()
  }

  // MARK: - Codex MCP servers (~/.codex/config.toml)

  func detectCodexMCPServers() -> [String] {
    let url = homeDirectory
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("config.toml", isDirectory: false)
    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
      return []
    }

    var names = Set<String>()
    // Match `[mcp_servers.<name>]` table headers; a sub-table like
    // `[mcp_servers.<name>.env]` contributes the same first segment.
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") else { continue }
      let inner = trimmed.dropFirst("[mcp_servers.".count).dropLast()
      let firstSegment = inner.split(separator: ".").first.map(String.init) ?? ""
      let cleaned = firstSegment.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      if !cleaned.isEmpty { names.insert(cleaned) }
    }
    return names.sorted()
  }
}
