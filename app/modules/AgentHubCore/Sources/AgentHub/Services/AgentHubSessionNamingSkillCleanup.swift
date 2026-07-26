import Foundation

/// Removes the session-naming skill that earlier AgentHub builds installed into
/// the user's home directory.
///
/// Naming is driven entirely by the `agenthub_name_session` MCP tool now. The
/// skill was a second copy of the same instructions behind an extra discovery
/// hop: Codex never took it, Claude took it inconsistently, and both paid its
/// tokens. Worse, a leftover `SKILL.md` still points at the old two-step
/// `name_session` contract, so it actively misleads agents — hence the sweep on
/// every launch rather than a one-shot migration.
enum AgentHubSessionNamingSkillCleanup {
  static let skillName = "agenthub-session-naming"

  /// Skill directories AgentHub used to write, relative to the home directory.
  private static let installedSkillParentPaths = [
    ".claude/skills",
    ".agents/skills",
  ]

  static func removeInstalledSkillBestEffort(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    for parentPath in installedSkillParentPaths {
      let skillDirectory = homeDirectory
        .appendingPathComponent(parentPath, isDirectory: true)
        .appendingPathComponent(skillName, isDirectory: true)
      guard fileManager.fileExists(atPath: skillDirectory.path) else { continue }

      do {
        try fileManager.removeItem(at: skillDirectory)
      } catch {
        AppLogger.session.error(
          "Failed to remove legacy AgentHub session naming skill at \(skillDirectory.path): \(error.localizedDescription)"
        )
      }
    }
  }
}
