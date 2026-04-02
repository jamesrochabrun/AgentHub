//
//  WorktreeBranchNaming.swift
//  AgentHub
//

import Foundation

public enum WorktreeBranchNamingLaunchContext: String, Sendable, Codable {
  case manualWorktree
  case smartFallback
}

public enum WorktreeBranchNameSource: String, Sendable, Codable {
  case ai
  case deterministicFallback
}

public struct WorktreeBranchNamingRequest: Sendable, Equatable {
  public let repoName: String
  public let repoPath: String
  public let baseBranchName: String?
  public let launchContext: WorktreeBranchNamingLaunchContext
  public let promptText: String
  public let attachmentBasenames: [String]
  public let providerKinds: [SessionProviderKind]

  public init(
    repoName: String,
    repoPath: String,
    baseBranchName: String?,
    launchContext: WorktreeBranchNamingLaunchContext,
    promptText: String,
    attachmentBasenames: [String],
    providerKinds: [SessionProviderKind]
  ) {
    self.repoName = repoName
    self.repoPath = repoPath
    self.baseBranchName = baseBranchName
    self.launchContext = launchContext
    self.promptText = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    self.attachmentBasenames = Array(attachmentBasenames.prefix(3))
    self.providerKinds = providerKinds
  }

  public var hasMeaningfulContext: Bool {
    !promptText.isEmpty || !attachmentBasenames.isEmpty
  }
}

public struct WorktreeBranchNamingResult: Sendable, Equatable {
  public let single: String?
  public let claude: String?
  public let codex: String?
  public let source: WorktreeBranchNameSource

  public init(
    single: String? = nil,
    claude: String? = nil,
    codex: String? = nil,
    source: WorktreeBranchNameSource
  ) {
    self.single = single
    self.claude = claude
    self.codex = codex
    self.source = source
  }
}

public struct WorktreeBranchNamingSettings: Sendable, Equatable {
  public let rawPrefix: String

  public init(rawPrefix: String = "") {
    self.rawPrefix = rawPrefix
  }

  public static func load(from defaults: UserDefaults = .standard) -> WorktreeBranchNamingSettings {
    WorktreeBranchNamingSettings(
      rawPrefix: defaults.string(forKey: AgentHubDefaults.worktreeBranchPrefix) ?? ""
    )
  }

  public var normalizedPrefix: String {
    Self.normalizePrefix(rawPrefix)
  }

  public func previewBranchName(stem: String = "smart-login-fix-ab12cd") -> String {
    normalizedPrefix + stem
  }

  public static func normalizePrefix(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let segments = trimmed
      .split(separator: "/")
      .compactMap { segment -> String? in
        let ascii = String(segment)
          .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
          .lowercased()
        let sanitized = ascii
          .replacingOccurrences(of: "_", with: "-")
          .components(separatedBy: CharacterSet.alphanumerics.inverted)
          .filter { !$0.isEmpty }
          .joined(separator: "-")
          .trimmingCharacters(in: CharacterSet(charactersIn: "-."))

        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(24))
      }

    guard !segments.isEmpty else { return "" }
    return segments.joined(separator: "/") + "/"
  }
}
