//
//  SkillsService.swift
//  AgentHub
//
//  Discovers and merges skills/custom commands from Claude and Codex data directories.
//

import Foundation

/// Reads skills and custom commands from the file system and merges them into a unified list.
///
/// Scans:
/// - `~/.claude/commands/*.md` (Claude global commands)
/// - `~/.claude/skills/*/SKILL.md` (Claude global skills)
/// - `{project}/.claude/commands/*.md` (Claude project commands)
/// - `{project}/.claude/skills/*/SKILL.md` (Claude project skills)
/// - `~/.codex/skills/*/SKILL.md` (Codex global skills, hidden dirs skipped)
/// - `~/.codex/skills/.system/*/SKILL.md` (Codex system skills)
public actor SkillsService {

  public init() {}

  /// Loads and merges all available skills.
  /// - Parameters:
  ///   - claudeDataPath: Path to the Claude data directory (default `~/.claude`)
  ///   - codexDataPath: Path to the Codex data directory (default `~/.codex`)
  ///   - projectPath: Optional project root path for project-scoped skills
  /// - Returns: Deduplicated, merged array of skills
  public func load(
    claudeDataPath: String,
    codexDataPath: String,
    projectPath: String?
  ) async -> [HubSkill] {
    var skills: [HubSkill] = []

    // Claude global commands
    skills += loadCommands(from: claudeDataPath + "/commands", source: .claudeGlobal)

    // Claude global skills
    skills += loadSkillDirectories(from: claudeDataPath + "/skills", source: .claudeGlobal)

    // Claude project-level commands and skills
    if let projectPath {
      let projectClaude = projectPath + "/.claude"
      skills += loadCommands(from: projectClaude + "/commands", source: .claudeProject)
      skills += loadSkillDirectories(from: projectClaude + "/skills", source: .claudeProject)
    }

    // Codex global skills (skip hidden directories like .system)
    skills += loadSkillDirectories(from: codexDataPath + "/skills", source: .codexGlobal, skipHidden: true)

    // Codex system skills
    skills += loadSkillDirectories(from: codexDataPath + "/skills/.system", source: .codexSystem)

    // Deduplicate by id, preserving order
    var seen = Set<String>()
    return skills.filter { seen.insert($0.id).inserted }
  }

  // MARK: - Private helpers

  /// Loads `*.md` files from a flat commands directory (Claude slash commands).
  private func loadCommands(from dir: String, source: HubSkill.Source) -> [HubSkill] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir),
          let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

    return entries.compactMap { filename -> HubSkill? in
      guard filename.hasSuffix(".md") else { return nil }
      let filePath = dir + "/" + filename
      guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
      let fm = parseFrontmatter(content)
      let name = String(filename.dropLast(3)) // strip ".md"
      let description = fm["description"] ?? ""
      let hint = fm["argument-hint"]
      return HubSkill(name: name, description: description, source: source, argumentHint: hint)
    }
  }

  /// Loads `{name}/SKILL.md` entries from a skills directory.
  private func loadSkillDirectories(
    from dir: String,
    source: HubSkill.Source,
    skipHidden: Bool = false
  ) -> [HubSkill] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir),
          let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

    return entries.compactMap { skillName -> HubSkill? in
      if skipHidden && skillName.hasPrefix(".") { return nil }
      let skillFile = dir + "/" + skillName + "/SKILL.md"
      guard fm.fileExists(atPath: skillFile),
            let content = try? String(contentsOfFile: skillFile, encoding: .utf8) else { return nil }
      let fm = parseFrontmatter(content)
      let name = fm["name"] ?? skillName
      let description = fm["description"] ?? ""
      return HubSkill(name: name, description: description, source: source)
    }
  }

  /// Parses the YAML frontmatter block (between `---` delimiters) into a key-value dictionary.
  private func parseFrontmatter(_ content: String) -> [String: String] {
    var result: [String: String] = [:]
    var inBlock = false
    var started = false

    for line in content.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "---" {
        if !started {
          started = true
          inBlock = true
        } else if inBlock {
          break
        }
        continue
      }
      guard inBlock else { continue }
      // Split only on the first colon to handle values containing colons
      if let colonRange = trimmed.range(of: ":") {
        let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound])
          .trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[colonRange.upperBound...])
          .trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if !key.isEmpty {
          result[key] = value
        }
      }
    }
    return result
  }
}
