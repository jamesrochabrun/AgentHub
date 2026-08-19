import Foundation

/// Installs the bundled `agenthub-studio` skill for Claude and Codex, the same
/// way the task-manager skill is installed: an explicit `/agenthub-studio`
/// trigger, plus a description the model can match on its own. The
/// system-prompt guidance (`StudioAgentGuidance`) does the everyday nudging;
/// the skill is the user's explicit handle and the fuller playbook.
enum AgentHubStudioSkillInstaller {
  static let skillName = "agenthub-studio"

  enum InstallError: LocalizedError {
    case missingBundledSkill
    case invalidBundledSkillEncoding
    case missingBundledOpenAIMetadata
    case invalidBundledOpenAIMetadataEncoding

    var errorDescription: String? {
      switch self {
      case .missingBundledSkill: return "Missing bundled AgentHub Studio skill."
      case .invalidBundledSkillEncoding: return "Bundled AgentHub Studio skill is not valid UTF-8."
      case .missingBundledOpenAIMetadata: return "Missing bundled AgentHub Studio OpenAI metadata."
      case .invalidBundledOpenAIMetadataEncoding: return "Bundled AgentHub Studio OpenAI metadata is not valid UTF-8."
      }
    }
  }

  static func installBundledSkillForAllProvidersBestEffort(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundle: Bundle = .module,
    fileManager: FileManager = .default
  ) {
    do {
      try installBundledSkillForAllProviders(homeDirectory: homeDirectory, bundle: bundle, fileManager: fileManager)
    } catch {
      AppLogger.session.error("Failed to install AgentHub Studio skill: \(error.localizedDescription)")
    }
  }

  static func installBundledSkillForAllProviders(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundle: Bundle = .module,
    fileManager: FileManager = .default
  ) throws {
    guard let skillURL = bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "AgentHubStudioSkill") else {
      throw InstallError.missingBundledSkill
    }
    guard let skillMarkdown = String(data: try Data(contentsOf: skillURL), encoding: .utf8) else {
      throw InstallError.invalidBundledSkillEncoding
    }
    guard let openAIYAMLURL = bundle.url(forResource: "openai", withExtension: "yaml", subdirectory: "AgentHubStudioSkill/agents") else {
      throw InstallError.missingBundledOpenAIMetadata
    }
    guard let openAIYAML = String(data: try Data(contentsOf: openAIYAMLURL), encoding: .utf8) else {
      throw InstallError.invalidBundledOpenAIMetadataEncoding
    }
    try AgentHubBundledSkillFiles.installForAllProviders(
      skillName: skillName,
      homeDirectory: homeDirectory,
      fileManager: fileManager,
      skillMarkdown: skillMarkdown,
      openAIYAML: openAIYAML
    )
  }
}
