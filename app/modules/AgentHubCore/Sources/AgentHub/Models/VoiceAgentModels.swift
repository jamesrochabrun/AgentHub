import Foundation

public struct VoiceSessionSummary: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let provider: SessionProviderKind
  public let worktree: String
  public let status: String
  public let pendingApprovalTool: String?
  public let secondsSinceActivity: Int
  public let localhostURL: String?

  public init(
    id: String,
    name: String,
    provider: SessionProviderKind,
    worktree: String,
    status: String,
    pendingApprovalTool: String?,
    secondsSinceActivity: Int,
    localhostURL: String?
  ) {
    self.id = id
    self.name = name
    self.provider = provider
    self.worktree = worktree
    self.status = status
    self.pendingApprovalTool = pendingApprovalTool
    self.secondsSinceActivity = secondsSinceActivity
    self.localhostURL = localhostURL
  }
}

public struct VoiceSessionsSummary: Codable, Equatable, Sendable {
  public let sessions: [VoiceSessionSummary]
  public let targetSessionId: String?

  public init(sessions: [VoiceSessionSummary], targetSessionId: String?) {
    self.sessions = sessions
    self.targetSessionId = targetSessionId
  }
}

public struct VoiceSessionActivity: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let description: String

  public init(timestamp: Date, description: String) {
    self.timestamp = timestamp
    self.description = description
  }
}

public struct VoiceSessionStatusDetail: Codable, Equatable, Sendable {
  public let sessionId: String
  public let provider: SessionProviderKind
  public let name: String
  public let status: String
  public let currentTool: String?
  public let contextUsagePercent: Double?
  public let pendingApproval: VoicePendingApproval?
  public let recentActivities: [VoiceSessionActivity]

  public init(
    sessionId: String,
    provider: SessionProviderKind,
    name: String,
    status: String,
    currentTool: String?,
    contextUsagePercent: Double?,
    pendingApproval: VoicePendingApproval?,
    recentActivities: [VoiceSessionActivity]
  ) {
    self.sessionId = sessionId
    self.provider = provider
    self.name = name
    self.status = status
    self.currentTool = currentTool
    self.contextUsagePercent = contextUsagePercent
    self.pendingApproval = pendingApproval
    self.recentActivities = recentActivities
  }
}

public struct VoicePromptDeliveryResult: Codable, Equatable, Sendable {
  public let status: String
  public let sessionId: String
  public let usedExistingTerminal: Bool

  public init(status: String, sessionId: String, usedExistingTerminal: Bool) {
    self.status = status
    self.sessionId = sessionId
    self.usedExistingTerminal = usedExistingTerminal
  }
}

public struct VoiceLaunchResult: Codable, Equatable, Sendable {
  public let status: String
  public let provider: SessionProviderKind
  public let worktreePath: String
  public let pendingSessionId: String?

  public init(
    status: String,
    provider: SessionProviderKind,
    worktreePath: String,
    pendingSessionId: String?
  ) {
    self.status = status
    self.provider = provider
    self.worktreePath = worktreePath
    self.pendingSessionId = pendingSessionId
  }
}

public struct VoicePendingApproval: Codable, Equatable, Sendable {
  public let sessionId: String
  public let provider: SessionProviderKind
  public let toolName: String
  public let toolUseId: String
  public let detail: String?

  public init(
    sessionId: String,
    provider: SessionProviderKind,
    toolName: String,
    toolUseId: String,
    detail: String?
  ) {
    self.sessionId = sessionId
    self.provider = provider
    self.toolName = toolName
    self.toolUseId = toolUseId
    self.detail = detail
  }
}

public struct VoiceApprovalResponseResult: Codable, Equatable, Sendable {
  public let status: String
  public let sessionId: String
  public let decision: String

  public init(status: String, sessionId: String, decision: String) {
    self.status = status
    self.sessionId = sessionId
    self.decision = decision
  }
}

public struct VoiceLatestResponse: Codable, Equatable, Sendable {
  public let sessionId: String
  public let provider: SessionProviderKind
  public let name: String
  public let text: String

  public init(
    sessionId: String,
    provider: SessionProviderKind,
    name: String,
    text: String
  ) {
    self.sessionId = sessionId
    self.provider = provider
    self.name = name
    self.text = text
  }
}

public struct VoiceWorktreeSummary: Codable, Equatable, Sendable {
  public let name: String
  public let path: String
  public let isWorktree: Bool
  public let sessionCount: Int

  public init(
    name: String,
    path: String,
    isWorktree: Bool,
    sessionCount: Int
  ) {
    self.name = name
    self.path = path
    self.isWorktree = isWorktree
    self.sessionCount = sessionCount
  }
}

public struct VoiceRepositorySummary: Codable, Equatable, Sendable {
  public let name: String
  public let path: String
  public let worktrees: [VoiceWorktreeSummary]

  public init(name: String, path: String, worktrees: [VoiceWorktreeSummary]) {
    self.name = name
    self.path = path
    self.worktrees = worktrees
  }
}

public struct VoiceWorktreeInventory: Codable, Equatable, Sendable {
  public let repositories: [VoiceRepositorySummary]

  public init(repositories: [VoiceRepositorySummary]) {
    self.repositories = repositories
  }
}

public struct VoiceWorktreeTaskSpec: Equatable, Sendable {
  public let branch: String
  public let prompt: String
  public let provider: SessionProviderKind

  public init(branch: String, prompt: String, provider: SessionProviderKind) {
    self.branch = branch
    self.prompt = prompt
    self.provider = provider
  }
}

public struct VoiceCreatedWorktree: Equatable, Sendable {
  public let repositoryPath: String
  public let branchName: String
  public let worktreePath: String
  public let launchPath: String?

  public init(
    repositoryPath: String,
    branchName: String,
    worktreePath: String,
    launchPath: String?
  ) {
    self.repositoryPath = repositoryPath
    self.branchName = branchName
    self.worktreePath = worktreePath
    self.launchPath = launchPath
  }
}

public struct VoiceWorktreeTaskLaunch: Codable, Equatable, Sendable {
  public let branch: String
  public let provider: SessionProviderKind
  public let worktreePath: String
  public let pendingSessionId: String?

  public init(
    branch: String,
    provider: SessionProviderKind,
    worktreePath: String,
    pendingSessionId: String?
  ) {
    self.branch = branch
    self.provider = provider
    self.worktreePath = worktreePath
    self.pendingSessionId = pendingSessionId
  }
}

public struct VoiceWorktreeTaskFailure: Codable, Equatable, Sendable {
  public let branch: String
  public let message: String

  public init(branch: String, message: String) {
    self.branch = branch
    self.message = message
  }
}

public struct VoiceWorktreeTaskBatchResult: Codable, Equatable, Sendable {
  public let status: String
  public let message: String?
  public let repositoryPath: String
  public let launched: [VoiceWorktreeTaskLaunch]
  public let failures: [VoiceWorktreeTaskFailure]

  public init(
    status: String,
    message: String?,
    repositoryPath: String,
    launched: [VoiceWorktreeTaskLaunch],
    failures: [VoiceWorktreeTaskFailure]
  ) {
    self.status = status
    self.message = message
    self.repositoryPath = repositoryPath
    self.launched = launched
    self.failures = failures
  }
}

public struct VoiceSessionTarget: Codable, Equatable, Sendable, Identifiable {
  public let sessionId: String
  public let provider: SessionProviderKind
  public let name: String
  public let projectPath: String
  public let lastActivityAt: Date

  public var id: String {
    "\(provider.rawValue):\(sessionId)"
  }

  public init(
    sessionId: String,
    provider: SessionProviderKind,
    name: String,
    projectPath: String,
    lastActivityAt: Date
  ) {
    self.sessionId = sessionId
    self.provider = provider
    self.name = name
    self.projectPath = projectPath
    self.lastActivityAt = lastActivityAt
  }
}
