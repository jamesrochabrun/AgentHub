//
//  HubSkill.swift
//  AgentHub
//
//  Unified model representing a skill or custom command from Claude or Codex.
//

import Foundation

/// A unified skill or custom slash command discovered from Claude or Codex data directories.
public struct HubSkill: Identifiable, Sendable {

  public var id: String { "\(source.storageKey):\(name)" }

  /// The skill name (used as the slash command trigger, e.g. `/swiftui-animation`)
  public let name: String

  /// Human-readable description from the skill's frontmatter
  public let description: String

  /// Where the skill was discovered
  public let source: Source

  /// Argument hint from Claude command frontmatter (e.g. `[message]`)
  public let argumentHint: String?

  public enum Source: Sendable {
    case claudeGlobal   // ~/.claude/commands/*.md or ~/.claude/skills/*/SKILL.md
    case claudeProject  // {project}/.claude/commands/*.md or {project}/.claude/skills/*/SKILL.md
    case codexGlobal    // ~/.codex/skills/*/SKILL.md
    case codexSystem    // ~/.codex/skills/.system/*/SKILL.md

    /// Short label shown in the picker badge
    public var displayLabel: String {
      switch self {
      case .claudeGlobal:  "Global"
      case .claudeProject: "Project"
      case .codexGlobal:   "Global"
      case .codexSystem:   "System"
      }
    }

    /// Unique key used to build `id` (avoids collisions between providers)
    var storageKey: String {
      switch self {
      case .claudeGlobal:  "claude-global"
      case .claudeProject: "claude-project"
      case .codexGlobal:   "codex-global"
      case .codexSystem:   "codex-system"
      }
    }

    /// The CLI provider this skill belongs to
    public var provider: Provider {
      switch self {
      case .claudeGlobal, .claudeProject: .claude
      case .codexGlobal, .codexSystem:    .codex
      }
    }
  }

  public enum Provider: String, Sendable {
    case claude
    case codex
  }

  public init(name: String, description: String, source: Source, argumentHint: String? = nil) {
    self.name = name
    self.description = description
    self.source = source
    self.argumentHint = argumentHint
  }
}
