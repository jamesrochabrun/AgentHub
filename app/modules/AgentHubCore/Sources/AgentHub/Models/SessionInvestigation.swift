//
//  SessionInvestigation.swift
//  AgentHub
//
//  Models for local session investigations and MCP-UI style resources.
//

import Foundation

public struct SessionInvestigationSnapshot: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let generatedAt: Date
  public let repositories: [SessionInvestigationRepositorySnapshot]
  public let worktrees: [SessionInvestigationWorktreeSnapshot]
  public let sessions: [SessionInvestigationSessionSnapshot]
  public let pendingSessions: [SessionInvestigationPendingSessionSnapshot]

  public init(
    id: UUID = UUID(),
    generatedAt: Date = Date(),
    repositories: [SessionInvestigationRepositorySnapshot],
    worktrees: [SessionInvestigationWorktreeSnapshot],
    sessions: [SessionInvestigationSessionSnapshot],
    pendingSessions: [SessionInvestigationPendingSessionSnapshot] = []
  ) {
    self.id = id
    self.generatedAt = generatedAt
    self.repositories = repositories
    self.worktrees = worktrees
    self.sessions = sessions
    self.pendingSessions = pendingSessions
  }

  public var overview: SessionInvestigationOverview {
    let monitoredSessions = sessions.filter(\.isMonitored).count
    let activeSessions = sessions.filter(\.isActive).count + pendingSessions.count
    let worktreeSessions = sessions.filter(\.isWorktree).count
    let awaitingApprovalSessions = sessions.filter(\.isAwaitingApproval).count
    let workingSessions = sessions.filter { session in
      guard let status = session.status?.lowercased() else { return false }
      return status.contains("working") || status.contains("tool:") || status.contains("executing")
    }.count + pendingSessions.count

    return SessionInvestigationOverview(
      repositoryCount: repositories.count,
      worktreeCount: worktrees.filter(\.isWorktree).count,
      sessionCount: sessions.count,
      monitoredSessionCount: monitoredSessions,
      activeSessionCount: activeSessions,
      worktreeSessionCount: worktreeSessions,
      pendingSessionCount: pendingSessions.count,
      awaitingApprovalSessionCount: awaitingApprovalSessions,
      workingSessionCount: workingSessions
    )
  }
}

public struct SessionInvestigationRepositorySnapshot: Codable, Sendable, Equatable, Identifiable {
  public var id: String { path }
  public let name: String
  public let path: String
  public let worktreeCount: Int
  public let sessionCount: Int

  public init(name: String, path: String, worktreeCount: Int, sessionCount: Int) {
    self.name = name
    self.path = path
    self.worktreeCount = worktreeCount
    self.sessionCount = sessionCount
  }
}

public struct SessionInvestigationWorktreeSnapshot: Codable, Sendable, Equatable, Identifiable {
  public var id: String { path }
  public let name: String
  public let path: String
  public let repositoryPath: String
  public let isWorktree: Bool
  public let sessionCount: Int
  public let activeSessionCount: Int
  public let latestActivityAt: Date?

  public init(
    name: String,
    path: String,
    repositoryPath: String,
    isWorktree: Bool,
    sessionCount: Int,
    activeSessionCount: Int,
    latestActivityAt: Date?
  ) {
    self.name = name
    self.path = path
    self.repositoryPath = repositoryPath
    self.isWorktree = isWorktree
    self.sessionCount = sessionCount
    self.activeSessionCount = activeSessionCount
    self.latestActivityAt = latestActivityAt
  }
}

public struct SessionInvestigationSessionSnapshot: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let provider: SessionProviderKind
  public let displayName: String
  public let projectPath: String
  public let repositoryPath: String?
  public let worktreePath: String?
  public let branchName: String?
  public let isWorktree: Bool
  public let isActive: Bool
  public let isMonitored: Bool
  public let status: String?
  public let currentTool: String?
  public let model: String?
  public let inputTokens: Int
  public let outputTokens: Int
  public let contextUsagePercent: Double?
  public let messageCount: Int
  public let lastActivityAt: Date
  public let firstMessagePreview: String?
  public let lastMessagePreview: String?
  public let sessionFilePath: String?
  public let sessionFileExists: Bool
  public let sessionFileByteCount: Int?
  public let sessionFileModifiedAt: Date?
  public let localhostURL: String?
  public let isAwaitingApproval: Bool

  public init(
    id: String,
    provider: SessionProviderKind,
    displayName: String,
    projectPath: String,
    repositoryPath: String?,
    worktreePath: String?,
    branchName: String?,
    isWorktree: Bool,
    isActive: Bool,
    isMonitored: Bool,
    status: String?,
    currentTool: String?,
    model: String?,
    inputTokens: Int,
    outputTokens: Int,
    contextUsagePercent: Double?,
    messageCount: Int,
    lastActivityAt: Date,
    firstMessagePreview: String?,
    lastMessagePreview: String?,
    sessionFilePath: String?,
    sessionFileExists: Bool,
    sessionFileByteCount: Int?,
    sessionFileModifiedAt: Date?,
    localhostURL: String?,
    isAwaitingApproval: Bool
  ) {
    self.id = id
    self.provider = provider
    self.displayName = displayName
    self.projectPath = projectPath
    self.repositoryPath = repositoryPath
    self.worktreePath = worktreePath
    self.branchName = branchName
    self.isWorktree = isWorktree
    self.isActive = isActive
    self.isMonitored = isMonitored
    self.status = status
    self.currentTool = currentTool
    self.model = model
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.contextUsagePercent = contextUsagePercent
    self.messageCount = messageCount
    self.lastActivityAt = lastActivityAt
    self.firstMessagePreview = firstMessagePreview
    self.lastMessagePreview = lastMessagePreview
    self.sessionFilePath = sessionFilePath
    self.sessionFileExists = sessionFileExists
    self.sessionFileByteCount = sessionFileByteCount
    self.sessionFileModifiedAt = sessionFileModifiedAt
    self.localhostURL = localhostURL
    self.isAwaitingApproval = isAwaitingApproval
  }
}

public struct SessionInvestigationPendingSessionSnapshot: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let provider: SessionProviderKind
  public let worktreeName: String
  public let worktreePath: String
  public let startedAt: Date

  public init(
    id: UUID,
    provider: SessionProviderKind,
    worktreeName: String,
    worktreePath: String,
    startedAt: Date
  ) {
    self.id = id
    self.provider = provider
    self.worktreeName = worktreeName
    self.worktreePath = worktreePath
    self.startedAt = startedAt
  }
}

public struct SessionInvestigationOverview: Codable, Sendable, Equatable {
  public let repositoryCount: Int
  public let worktreeCount: Int
  public let sessionCount: Int
  public let monitoredSessionCount: Int
  public let activeSessionCount: Int
  public let worktreeSessionCount: Int
  public let pendingSessionCount: Int
  public let awaitingApprovalSessionCount: Int
  public let workingSessionCount: Int

  public init(
    repositoryCount: Int,
    worktreeCount: Int,
    sessionCount: Int,
    monitoredSessionCount: Int,
    activeSessionCount: Int,
    worktreeSessionCount: Int,
    pendingSessionCount: Int,
    awaitingApprovalSessionCount: Int,
    workingSessionCount: Int
  ) {
    self.repositoryCount = repositoryCount
    self.worktreeCount = worktreeCount
    self.sessionCount = sessionCount
    self.monitoredSessionCount = monitoredSessionCount
    self.activeSessionCount = activeSessionCount
    self.worktreeSessionCount = worktreeSessionCount
    self.pendingSessionCount = pendingSessionCount
    self.awaitingApprovalSessionCount = awaitingApprovalSessionCount
    self.workingSessionCount = workingSessionCount
  }
}

public enum SessionInvestigationSeverity: String, Codable, Sendable, Equatable, CaseIterable {
  case info
  case warning
  case critical
}

public enum SessionInvestigationActionCategory: String, Codable, Sendable, Equatable, CaseIterable {
  case scale
  case observe
  case needsAttention
  case mergeCandidate
  case merged
  case deleteWorktreeCandidate
  case removeFromHub
  case cleanup
  case unknown
}

public enum SessionInvestigationConfidence: String, Codable, Sendable, Equatable, CaseIterable {
  case low
  case medium
  case high
}

public struct SessionInvestigationFinding: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let title: String
  public let detail: String
  public let severity: SessionInvestigationSeverity
  public let provider: SessionProviderKind?
  public let sessionIds: [String]
  public let projectPath: String?
  public let worktreePath: String?

  public init(
    id: UUID = UUID(),
    title: String,
    detail: String,
    severity: SessionInvestigationSeverity,
    provider: SessionProviderKind? = nil,
    sessionIds: [String] = [],
    projectPath: String? = nil,
    worktreePath: String? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.severity = severity
    self.provider = provider
    self.sessionIds = sessionIds
    self.projectPath = projectPath
    self.worktreePath = worktreePath
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    self.title = try container.decode(String.self, forKey: .title)
    self.detail = try container.decode(String.self, forKey: .detail)
    self.severity = try container.decode(SessionInvestigationSeverity.self, forKey: .severity)
    self.provider = try container.decodeIfPresent(SessionProviderKind.self, forKey: .provider)
    self.sessionIds = try container.decodeIfPresent([String].self, forKey: .sessionIds) ?? []
    self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
    self.worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
  }
}

public struct SessionInvestigationAction: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let title: String
  public let detail: String
  public let category: SessionInvestigationActionCategory
  public let confidence: SessionInvestigationConfidence
  public let provider: SessionProviderKind?
  public let sessionIds: [String]
  public let projectPath: String?
  public let worktreePath: String?

  public init(
    id: UUID = UUID(),
    title: String,
    detail: String,
    category: SessionInvestigationActionCategory,
    confidence: SessionInvestigationConfidence,
    provider: SessionProviderKind? = nil,
    sessionIds: [String] = [],
    projectPath: String? = nil,
    worktreePath: String? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.category = category
    self.confidence = confidence
    self.provider = provider
    self.sessionIds = sessionIds
    self.projectPath = projectPath
    self.worktreePath = worktreePath
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    self.title = try container.decode(String.self, forKey: .title)
    self.detail = try container.decode(String.self, forKey: .detail)
    self.category = try container.decode(SessionInvestigationActionCategory.self, forKey: .category)
    self.confidence = try container.decode(SessionInvestigationConfidence.self, forKey: .confidence)
    self.provider = try container.decodeIfPresent(SessionProviderKind.self, forKey: .provider)
    self.sessionIds = try container.decodeIfPresent([String].self, forKey: .sessionIds) ?? []
    self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
    self.worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
  }
}

public enum SessionInvestigationReportSource: String, Codable, Sendable, Equatable {
  case claude
  case deterministicFallback
}

public struct SessionInvestigationReport: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let generatedAt: Date
  public let source: SessionInvestigationReportSource
  public let overview: SessionInvestigationOverview
  public let narrative: String
  public let findings: [SessionInvestigationFinding]
  public let actions: [SessionInvestigationAction]
  public let rawModelOutput: String?

  public init(
    id: UUID = UUID(),
    generatedAt: Date = Date(),
    source: SessionInvestigationReportSource,
    overview: SessionInvestigationOverview,
    narrative: String,
    findings: [SessionInvestigationFinding],
    actions: [SessionInvestigationAction],
    rawModelOutput: String? = nil
  ) {
    self.id = id
    self.generatedAt = generatedAt
    self.source = source
    self.overview = overview
    self.narrative = narrative
    self.findings = findings
    self.actions = actions
    self.rawModelOutput = rawModelOutput
  }
}
