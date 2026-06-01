import Foundation

enum AgentHubWorktreeSkillInstaller {
  static let skillName = "agenthub-worktrees"

  enum InstallError: LocalizedError {
    case missingBundledSkill
    case invalidBundledSkillEncoding
    case missingBundledOpenAIMetadata
    case invalidBundledOpenAIMetadataEncoding

    var errorDescription: String? {
      switch self {
      case .missingBundledSkill:
        return "Missing bundled AgentHub worktree skill."
      case .invalidBundledSkillEncoding:
        return "Bundled AgentHub worktree skill is not valid UTF-8."
      case .missingBundledOpenAIMetadata:
        return "Missing bundled AgentHub worktree OpenAI metadata."
      case .invalidBundledOpenAIMetadataEncoding:
        return "Bundled AgentHub worktree OpenAI metadata is not valid UTF-8."
      }
    }
  }

  static func installBundledSkillForAllProvidersBestEffort(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundle: Bundle = .module,
    fileManager: FileManager = .default
  ) {
    do {
      try installBundledSkillForAllProviders(
        homeDirectory: homeDirectory,
        bundle: bundle,
        fileManager: fileManager
      )
    } catch {
      AppLogger.session.error("Failed to install AgentHub worktree skill: \(error.localizedDescription)")
    }
  }

  static func installBundledSkillForAllProviders(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundle: Bundle = .module,
    fileManager: FileManager = .default
  ) throws {
    guard let skillURL = bundle.url(
      forResource: "SKILL",
      withExtension: "md",
      subdirectory: "AgentHubWorktreeSkill"
    ) else {
      throw InstallError.missingBundledSkill
    }
    guard let skillMarkdown = String(data: try Data(contentsOf: skillURL), encoding: .utf8) else {
      throw InstallError.invalidBundledSkillEncoding
    }

    guard let openAIYAMLURL = bundle.url(
      forResource: "openai",
      withExtension: "yaml",
      subdirectory: "AgentHubWorktreeSkill/agents"
    ) else {
      throw InstallError.missingBundledOpenAIMetadata
    }
    guard let openAIYAML = String(data: try Data(contentsOf: openAIYAMLURL), encoding: .utf8) else {
      throw InstallError.invalidBundledOpenAIMetadataEncoding
    }

    try installForAllProviders(
      homeDirectory: homeDirectory,
      fileManager: fileManager,
      skillMarkdown: skillMarkdown,
      openAIYAML: openAIYAML
    )
  }

  static func installForAllProviders(
    homeDirectory: URL,
    fileManager: FileManager = .default,
    skillMarkdown: String,
    openAIYAML: String
  ) throws {
    let claudeSkillDirectory = homeDirectory
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
      .appendingPathComponent(skillName, isDirectory: true)
    let codexSkillDirectory = homeDirectory
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
      .appendingPathComponent(skillName, isDirectory: true)

    try write(
      skillMarkdown,
      to: claudeSkillDirectory.appendingPathComponent("SKILL.md", isDirectory: false),
      fileManager: fileManager
    )
    try write(
      skillMarkdown,
      to: codexSkillDirectory.appendingPathComponent("SKILL.md", isDirectory: false),
      fileManager: fileManager
    )
    try write(
      openAIYAML,
      to: codexSkillDirectory
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("openai.yaml", isDirectory: false),
      fileManager: fileManager
    )
  }

  private static func write(
    _ content: String,
    to url: URL,
    fileManager: FileManager
  ) throws {
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let data = Data(content.utf8)
    if let existingData = try? Data(contentsOf: url), existingData == data {
      return
    }
    try data.write(to: url, options: .atomic)
  }
}
