//
//  SierraDefaultsBootstrap.swift
//  AgentHub
//

import Foundation

public protocol SierraDefaultsBootstrapProtocol: Sendable {
  func bootstrap() async
}

public final class SierraDefaultsBootstrap: SierraDefaultsBootstrapProtocol, @unchecked Sendable {
  private let metadataStore: SessionMetadataStore
  private let defaults: UserDefaults
  private let fileManager: FileManager
  private let homeDirectory: URL
  private let applicationSupportDirectory: URL

  public init(
    metadataStore: SessionMetadataStore,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    applicationSupportDirectory: URL? = nil
  ) {
    self.metadataStore = metadataStore
    self.defaults = defaults
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory
    self.applicationSupportDirectory = applicationSupportDirectory
      ?? homeDirectory
        .appendingPathComponent("Library/Application Support/AgentHub", isDirectory: true)
  }

  public func bootstrap() async {
    installClaudeWrapper()
    seedUserDefaults()
    await seedAIConfig()
    await seedWorkspaceState()
    defaults.set(true, forKey: AgentHubDefaults.sierraDefaultsBootstrapped)
  }

  private func seedUserDefaults() {
    if defaults.string(forKey: AgentHubDefaults.claudeCommand) == nil {
      defaults.set("agenthub-claude", forKey: AgentHubDefaults.claudeCommand)
    }

    if defaults.string(forKey: AgentHubDefaults.codexCommand) == nil {
      defaults.set("codex", forKey: AgentHubDefaults.codexCommand)
    }

    defaults.set(true, forKey: AgentHubDefaults.enabledProviders + ".claude")
    defaults.set(true, forKey: AgentHubDefaults.enabledProviders + ".codex")

    if defaults.string(forKey: AgentHubDefaults.worktreeBranchPrefix) == nil {
      defaults.set(usernameBranchPrefix(), forKey: AgentHubDefaults.worktreeBranchPrefix)
    }
  }

  private func seedAIConfig() async {
    await seedAIConfig(
      provider: "claude",
      defaultModel: "us.anthropic.claude-opus-4-8[1m]",
      effortLevel: "high"
    )
    await seedAIConfig(provider: "codex", defaultModel: "gpt-5.5", effortLevel: "high")
  }

  private func seedAIConfig(provider: String, defaultModel: String, effortLevel: String) async {
    do {
      if let existing = try await metadataStore.getAIConfig(for: provider),
         !existing.defaultModel.isEmpty || !existing.effortLevel.isEmpty {
        return
      }
      try await metadataStore.saveAIConfig(AIConfigRecord(
        provider: provider,
        defaultModel: defaultModel,
        effortLevel: effortLevel
      ))
    } catch {
      AppLogger.session.error("[SierraDefaults] Failed to seed AI config for \(provider): \(error.localizedDescription)")
    }
  }

  private func seedWorkspaceState() async {
    let paths = discoverRepositoryPaths()
    guard !paths.isEmpty else { return }

    for provider in [SessionProviderKind.claude, .codex] {
      let existing = metadataStore.getWorkspaceStateSync(for: provider)
      guard existing.selectedRepositoryPaths.isEmpty else { continue }
      let state = SessionWorkspaceState(
        selectedRepositoryPaths: paths,
        monitoredSessionIds: existing.monitoredSessionIds,
        ownedWorktreePaths: existing.ownedWorktreePaths,
        expansionState: Dictionary(uniqueKeysWithValues: paths.map { ("repo:" + $0, true) })
      )
      do {
        try await metadataStore.saveWorkspaceState(state, for: provider)
      } catch {
        AppLogger.session.error("[SierraDefaults] Failed to seed workspace state for \(provider.rawValue): \(error.localizedDescription)")
      }
    }
  }

  private func installClaudeWrapper() {
    let binDirectory = applicationSupportDirectory.appendingPathComponent("bin", isDirectory: true)
    let configDirectory = applicationSupportDirectory.appendingPathComponent("claude-config", isDirectory: true)
    let wrapperURL = binDirectory.appendingPathComponent("agenthub-claude")
    let settingsURL = configDirectory.appendingPathComponent("settings.json")
    let mcpConfigURL = configDirectory.appendingPathComponent("mcp-config.json")

    do {
      try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
      try wrapperScript(settingsPath: settingsURL.path, mcpConfigPath: mcpConfigURL.path)
        .write(to: wrapperURL, atomically: true, encoding: .utf8)
      try settingsJSON().write(to: settingsURL, atomically: true, encoding: .utf8)
      try mcpConfigJSON().write(to: mcpConfigURL, atomically: true, encoding: .utf8)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
    } catch {
      AppLogger.session.error("[SierraDefaults] Failed to install Claude wrapper: \(error.localizedDescription)")
    }
  }

  private func wrapperScript(settingsPath: String, mcpConfigPath: String) -> String {
    let localClaude = homeDirectory.appendingPathComponent(".local/bin/claude").path
    return """
    #!/usr/bin/env bash
    set -euo pipefail

    export PATH="\(homeDirectory.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
    export AWS_PROFILE="${AWS_PROFILE:-claudecode}"
    export AWS_REGION="${AWS_REGION:-us-west-2}"
    export CLAUDE_CODE_USE_BEDROCK="${CLAUDE_CODE_USE_BEDROCK:-1}"
    export ANTHROPIC_DEFAULT_FABLE_MODEL="${ANTHROPIC_DEFAULT_FABLE_MODEL:-us.anthropic.claude-fable-5}"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="${ANTHROPIC_DEFAULT_OPUS_MODEL:-us.anthropic.claude-opus-4-8[1m]}"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_DEFAULT_SONNET_MODEL:-us.anthropic.claude-sonnet-4-6}"
    export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-us.anthropic.claude-opus-4-8[1m]}"
    export CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-us.anthropic.claude-opus-4-8[1m]}"
    export TERM="${TERM:-xterm-256color}"
    export COLORTERM="${COLORTERM:-truecolor}"
    export CLICOLOR="${CLICOLOR:-1}"
    export CLICOLOR_FORCE="${CLICOLOR_FORCE:-1}"
    export FORCE_COLOR="${FORCE_COLOR:-1}"

    if [[ "${1:-}" == "claude" ]]; then
      shift
    fi
    if [[ "${1:-}" == "--" ]]; then
      shift
    fi

    permission_args=()
    has_permission_mode=0
    for arg in "$@"; do
      if [[ "$arg" == "--permission-mode" || "$arg" == "--dangerously-skip-permissions" ]]; then
        has_permission_mode=1
        break
      fi
    done
    if [[ "$has_permission_mode" == "0" ]]; then
      permission_args=(--permission-mode bypassPermissions)
    fi

    mcp_args=()
    if [[ -s "\(mcpConfigPath)" ]]; then
      mcp_args=(--mcp-config="\(mcpConfigPath)")
    fi

    if [[ -x "\(localClaude)" ]]; then
      exec "\(localClaude)" --setting-sources project,local --settings "\(settingsPath)" "${mcp_args[@]}" "${permission_args[@]}" "$@"
    fi

    exec claude --setting-sources project,local --settings "\(settingsPath)" "${mcp_args[@]}" "${permission_args[@]}" "$@"
    """
  }

  private func mcpConfigJSON() -> String {
    let claudeConfigURL = homeDirectory.appendingPathComponent(".claude.json")
    guard
      let data = try? Data(contentsOf: claudeConfigURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let mcpServers = object["mcpServers"] as? [String: Any]
    else {
      return "{\n  \"mcpServers\": {}\n}\n"
    }

    do {
      let mcpConfigData = try JSONSerialization.data(
        withJSONObject: ["mcpServers": mcpServers],
        options: [.prettyPrinted, .sortedKeys]
      )
      return String(data: mcpConfigData, encoding: .utf8).map { $0 + "\n" }
        ?? "{\n  \"mcpServers\": {}\n}\n"
    } catch {
      return "{\n  \"mcpServers\": {}\n}\n"
    }
  }

  private func settingsJSON() -> String {
    """
    {
      "awsAuthRefresh": "aws sso login --profile claudecode",
      "env": {
        "ENABLE_TOOL_SEARCH": "auto:0",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "300000"
      },
      "model": "opus",
      "effortLevel": "high",
      "enabledPlugins": {
        "figma@claude-plugins-official": true,
        "github@claude-plugins-official": true,
        "linear@claude-plugins-official": true,
        "claude-video-vision@claude-video-vision": true
      },
      "extraKnownMarketplaces": {
        "claude-video-vision": {
          "source": {
            "source": "git",
            "url": "https://github.com/jordanrendric/claude-video-vision.git"
          }
        }
      },
      "enableAllProjectMcpServers": true,
      "skipDangerousModePermissionPrompt": true,
      "permissions": {
        "defaultMode": "bypassPermissions",
        "allow": [
          "Bash(*)",
          "Read",
          "Write",
          "Edit",
          "MultiEdit",
          "Glob",
          "Grep",
          "WebFetch",
          "WebSearch",
          "Task",
          "Skill",
          "mcp__chrome-devtools__*",
          "mcp__cloudwatch-eu__*",
          "mcp__cloudwatch-sg__*",
          "mcp__cloudwatch-us__*",
          "mcp__dataresearch__*",
          "mcp__ffmpeg-comprehensive__*",
          "mcp__ffmpeg-lite__*",
          "mcp__ffmpeg-micro__*",
          "mcp__grafana-eu__*",
          "mcp__grafana-jp__*",
          "mcp__grafana-sg__*",
          "mcp__grafana-us__*",
          "mcp__linear__*",
          "mcp__linear-server__*",
          "mcp__ml-training__*",
          "mcp__pinewood__*",
          "mcp__plugin_claude-video-vision_claude-video-vision__*",
          "mcp__plugin_figma_figma__*",
          "mcp__plugin_github_github__*",
          "mcp__plugin_linear_linear__*",
          "mcp__playwright__*",
          "mcp__sierra__*",
          "mcp__sierra-dev__*",
          "mcp__sierra-tools__*",
          "mcp__video-analyzer__*"
        ]
      }
    }
    """
  }

  private func usernameBranchPrefix() -> String {
    NSUserName()
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  private func discoverRepositoryPaths() -> [String] {
    var paths: Set<String> = []
    addKnownRepositoryPaths(to: &paths)
    addConductorWorkspacePaths(to: &paths)
    addHomeChildGitRepositories(to: &paths)
    return paths.sorted()
  }

  private func addKnownRepositoryPaths(to paths: inout Set<String>) {
    let knownRelativePaths = [
      "sierra",
      "shopping-prototypes",
      "ticketmaster",
      "cityfurniture",
      "ulta",
      "modern-animal",
      "sonos",
      "shipt",
      "vivid-seats",
      "directv",
      "nordstrom"
    ]

    for relativePath in knownRelativePaths {
      insertGitRepository(homeDirectory.appendingPathComponent(relativePath).path, into: &paths)
    }

    let agentsDirectory = homeDirectory.appendingPathComponent("dev/agents-customer", isDirectory: true)
    addImmediateGitChildren(of: agentsDirectory, to: &paths)
  }

  private func addConductorWorkspacePaths(to paths: inout Set<String>) {
    let root = homeDirectory.appendingPathComponent("conductor/workspaces", isDirectory: true)
    guard let customers = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    for customer in customers {
      addImmediateGitChildren(of: customer, to: &paths)
    }
  }

  private func addHomeChildGitRepositories(to paths: inout Set<String>) {
    guard let children = try? fileManager.contentsOfDirectory(
      at: homeDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    let excluded = Set([
      "Applications",
      "Desktop",
      "Documents",
      "Downloads",
      "Library",
      "Movies",
      "Music",
      "Pictures",
      "Public",
      "node_modules",
      ".cache"
    ])

    for child in children where !excluded.contains(child.lastPathComponent) {
      insertGitRepository(child.path, into: &paths)
    }
  }

  private func addImmediateGitChildren(of directory: URL, to paths: inout Set<String>) {
    guard let children = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    for child in children {
      insertGitRepository(child.path, into: &paths)
    }
  }

  private func insertGitRepository(_ path: String, into paths: inout Set<String>) {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return
    }
    guard fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path) else {
      return
    }
    paths.insert(WorktreeModuleResolver.normalizedDirectoryPath(path))
  }
}
