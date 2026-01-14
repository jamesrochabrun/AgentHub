import Foundation

// MARK: - GlobalStatsCache

/// Represents the global stats from ~/.claude/stats-cache.json
public struct GlobalStatsCache: Decodable, Sendable {
  public let version: Int
  public let lastComputedDate: String
  public let dailyActivity: [DailyActivity]
  public let dailyModelTokens: [DailyModelTokens]?
  public let modelUsage: [String: ModelUsage]
  public let totalSessions: Int
  public let totalMessages: Int
  public let longestSession: LongestSession?
  public let firstSessionDate: String?
  public let hourCounts: [String: Int]?

  public init(
    version: Int = 1,
    lastComputedDate: String = "",
    dailyActivity: [DailyActivity] = [],
    dailyModelTokens: [DailyModelTokens]? = nil,
    modelUsage: [String: ModelUsage] = [:],
    totalSessions: Int = 0,
    totalMessages: Int = 0,
    longestSession: LongestSession? = nil,
    firstSessionDate: String? = nil,
    hourCounts: [String: Int]? = nil
  ) {
    self.version = version
    self.lastComputedDate = lastComputedDate
    self.dailyActivity = dailyActivity
    self.dailyModelTokens = dailyModelTokens
    self.modelUsage = modelUsage
    self.totalSessions = totalSessions
    self.totalMessages = totalMessages
    self.longestSession = longestSession
    self.firstSessionDate = firstSessionDate
    self.hourCounts = hourCounts
  }
}

// MARK: - ModelUsage

public struct ModelUsage: Decodable, Sendable {
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheReadInputTokens: Int
  public let cacheCreationInputTokens: Int
  public let webSearchRequests: Int?
  public let costUSD: Double?

  public init(
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cacheReadInputTokens: Int = 0,
    cacheCreationInputTokens: Int = 0,
    webSearchRequests: Int? = nil,
    costUSD: Double? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadInputTokens = cacheReadInputTokens
    self.cacheCreationInputTokens = cacheCreationInputTokens
    self.webSearchRequests = webSearchRequests
    self.costUSD = costUSD
  }

  /// Total tokens for this model
  public var totalTokens: Int {
    inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
  }
}

// MARK: - DailyActivity

public struct DailyActivity: Decodable, Sendable {
  public let date: String
  public let messageCount: Int
  public let sessionCount: Int
  public let toolCallCount: Int

  public init(
    date: String,
    messageCount: Int,
    sessionCount: Int,
    toolCallCount: Int
  ) {
    self.date = date
    self.messageCount = messageCount
    self.sessionCount = sessionCount
    self.toolCallCount = toolCallCount
  }
}

// MARK: - DailyModelTokens

public struct DailyModelTokens: Decodable, Sendable {
  public let date: String
  public let tokensByModel: [String: Int]

  public init(date: String, tokensByModel: [String: Int]) {
    self.date = date
    self.tokensByModel = tokensByModel
  }
}

// MARK: - LongestSession

public struct LongestSession: Decodable, Sendable {
  public let sessionId: String
  public let duration: Int
  public let messageCount: Int
  public let timestamp: String

  public init(
    sessionId: String,
    duration: Int,
    messageCount: Int,
    timestamp: String
  ) {
    self.sessionId = sessionId
    self.duration = duration
    self.messageCount = messageCount
    self.timestamp = timestamp
  }
}
