//
//  SessionMonitorState.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import Foundation
import PierreDiffsSwift

// MARK: - SessionMonitorState

/// Real-time monitoring state for a CLI session
public struct SessionMonitorState: Equatable, Sendable {
  // Activity
  public var status: SessionStatus
  public var currentTool: String?
  public var lastActivityAt: Date

  // Tokens
  public var inputTokens: Int
  public var outputTokens: Int
  public var cacheReadTokens: Int
  public var cacheCreationTokens: Int

  // Metrics
  public var messageCount: Int
  public var toolCalls: [String: Int]  // Tool name -> count
  public var sessionStartedAt: Date?
  public var model: String?
  public var gitBranch: String?

  // Pending approval detection
  public var pendingToolUse: PendingToolUse?

  // Recent activity log
  public var recentActivities: [ActivityEntry]

  public init(
    status: SessionStatus = .idle,
    currentTool: String? = nil,
    lastActivityAt: Date = Date(),
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cacheReadTokens: Int = 0,
    cacheCreationTokens: Int = 0,
    messageCount: Int = 0,
    toolCalls: [String: Int] = [:],
    sessionStartedAt: Date? = nil,
    model: String? = nil,
    gitBranch: String? = nil,
    pendingToolUse: PendingToolUse? = nil,
    recentActivities: [ActivityEntry] = []
  ) {
    self.status = status
    self.currentTool = currentTool
    self.lastActivityAt = lastActivityAt
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheCreationTokens = cacheCreationTokens
    self.messageCount = messageCount
    self.toolCalls = toolCalls
    self.sessionStartedAt = sessionStartedAt
    self.model = model
    self.gitBranch = gitBranch
    self.pendingToolUse = pendingToolUse
    self.recentActivities = recentActivities
  }

  // MARK: - Computed Properties

  public var totalTokens: Int {
    inputTokens + outputTokens
  }

  public var sessionDuration: TimeInterval? {
    guard let start = sessionStartedAt else { return nil }
    return lastActivityAt.timeIntervalSince(start)
  }

  public var isAwaitingApproval: Bool {
    pendingToolUse != nil
  }
}

// MARK: - SessionStatus

public enum SessionStatus: Equatable, Sendable {
  case thinking
  case executingTool(name: String)
  case waitingForUser
  case awaitingApproval(tool: String)
  case idle

  public var displayName: String {
    switch self {
    case .thinking:
      return "Working"
    case .executingTool(let name):
      return "Tool: \(name)"
    case .waitingForUser:
      return "Ready"
    case .awaitingApproval(let tool):
      return "Awaiting approval: \(tool)"
    case .idle:
      return "Idle"
    }
  }

  public var icon: String {
    switch self {
    case .thinking:
      return "brain"
    case .executingTool:
      return "gearshape"
    case .waitingForUser:
      return "checkmark.circle"
    case .awaitingApproval:
      return "exclamationmark.circle"
    case .idle:
      return "circle"
    }
  }

  public var color: String {
    switch self {
    case .thinking:
      return "blue"
    case .executingTool:
      return "orange"
    case .waitingForUser:
      return "green"
    case .awaitingApproval:
      return "yellow"
    case .idle:
      return "gray"
    }
  }
}

// MARK: - ActivityEntry

public struct ActivityEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let type: ActivityType
  public let description: String
  public let toolInput: CodeChangeInput?

  public init(
    id: UUID = UUID(),
    timestamp: Date,
    type: ActivityType,
    description: String,
    toolInput: CodeChangeInput? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.type = type
    self.description = description
    self.toolInput = toolInput
  }
}

// MARK: - CodeChangeInput

/// Holds full input parameters for code-changing tools (Edit, Write, MultiEdit)
public struct CodeChangeInput: Equatable, Sendable {
  public enum ToolType: String, Equatable, Sendable {
    case edit = "Edit"
    case write = "Write"
    case multiEdit = "MultiEdit"
  }

  public let toolType: ToolType
  public let filePath: String
  public let oldString: String?
  public let newString: String?
  public let replaceAll: Bool?
  public let edits: [[String: String]]?

  public init(
    toolType: ToolType,
    filePath: String,
    oldString: String? = nil,
    newString: String? = nil,
    replaceAll: Bool? = nil,
    edits: [[String: String]]? = nil
  ) {
    self.toolType = toolType
    self.filePath = filePath
    self.oldString = oldString
    self.newString = newString
    self.replaceAll = replaceAll
    self.edits = edits
  }

  public var fileName: String {
    URL(fileURLWithPath: filePath).lastPathComponent
  }
}

// MARK: - CodeChangeInput Extensions for PierreDiffsSwift

extension CodeChangeInput.ToolType {
  /// Converts to PierreDiffsSwift's EditTool enum
  public var editTool: EditTool {
    switch self {
    case .edit: return .edit
    case .write: return .write
    case .multiEdit: return .multiEdit
    }
  }
}

extension CodeChangeInput {
  /// Converts to tool parameters dictionary for DiffEditsView
  public func toToolParameters() -> [String: String] {
    var params: [String: String] = ["file_path": filePath]

    switch toolType {
    case .edit:
      if let old = oldString { params["old_string"] = old }
      if let new = newString { params["new_string"] = new }
      if let replaceAll = replaceAll { params["replace_all"] = String(replaceAll) }

    case .write:
      if let content = newString { params["content"] = content }

    case .multiEdit:
      if let edits = edits,
         let data = try? JSONSerialization.data(withJSONObject: edits),
         let string = String(data: data, encoding: .utf8) {
        params["edits"] = string
      }
    }
    return params
  }
}

// MARK: - ActivityType

public enum ActivityType: Equatable, Sendable {
  case toolUse(name: String)
  case toolResult(name: String, success: Bool)
  case userMessage
  case assistantMessage
  case thinking

  public var icon: String {
    switch self {
    case .toolUse:
      return "hammer"
    case .toolResult(_, let success):
      return success ? "checkmark.circle" : "xmark.circle"
    case .userMessage:
      return "person"
    case .assistantMessage:
      return "sparkles"
    case .thinking:
      return "brain"
    }
  }
}

// MARK: - PendingToolUse

/// Represents a tool use that hasn't received a result yet (possibly awaiting approval)
public struct PendingToolUse: Equatable, Sendable {
  public let toolName: String
  public let toolUseId: String
  public let timestamp: Date
  public let input: String?

  public init(
    toolName: String,
    toolUseId: String,
    timestamp: Date,
    input: String? = nil
  ) {
    self.toolName = toolName
    self.toolUseId = toolUseId
    self.timestamp = timestamp
    self.input = input
  }

  /// How long this tool has been pending
  public var pendingDuration: TimeInterval {
    Date().timeIntervalSince(timestamp)
  }

  /// Whether this is likely awaiting approval (pending > 2 seconds)
  public var isLikelyAwaitingApproval: Bool {
    pendingDuration > 2.0
  }
}

// MARK: - CostBreakdown

public struct CostBreakdown: Equatable, Sendable {
  public let inputCost: Decimal
  public let outputCost: Decimal
  public let cacheReadCost: Decimal
  public let cacheCreationCost: Decimal

  public var totalCost: Decimal {
    inputCost + outputCost + cacheReadCost + cacheCreationCost
  }

  public init(
    inputCost: Decimal = 0,
    outputCost: Decimal = 0,
    cacheReadCost: Decimal = 0,
    cacheCreationCost: Decimal = 0
  ) {
    self.inputCost = inputCost
    self.outputCost = outputCost
    self.cacheReadCost = cacheReadCost
    self.cacheCreationCost = cacheCreationCost
  }
}

// MARK: - CostCalculator

public struct CostCalculator {
  // Pricing per 1M tokens (as of 2025)
  // Claude Opus 4
  private static let opusInputPrice: Decimal = 15.0
  private static let opusOutputPrice: Decimal = 75.0
  private static let opusCacheReadPrice: Decimal = 1.50
  private static let opusCacheCreationPrice: Decimal = 18.75

  // Claude Sonnet 4
  private static let sonnetInputPrice: Decimal = 3.0
  private static let sonnetOutputPrice: Decimal = 15.0
  private static let sonnetCacheReadPrice: Decimal = 0.30
  private static let sonnetCacheCreationPrice: Decimal = 3.75

  // Claude Haiku
  private static let haikuInputPrice: Decimal = 0.25
  private static let haikuOutputPrice: Decimal = 1.25
  private static let haikuCacheReadPrice: Decimal = 0.025
  private static let haikuCacheCreationPrice: Decimal = 0.30

  public static func calculate(
    model: String?,
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int,
    cacheCreationTokens: Int
  ) -> CostBreakdown {
    let prices = getPrices(for: model)

    let inputCost = Decimal(inputTokens) * prices.input / 1_000_000
    let outputCost = Decimal(outputTokens) * prices.output / 1_000_000
    let cacheReadCost = Decimal(cacheReadTokens) * prices.cacheRead / 1_000_000
    let cacheCreationCost = Decimal(cacheCreationTokens) * prices.cacheCreation / 1_000_000

    return CostBreakdown(
      inputCost: inputCost,
      outputCost: outputCost,
      cacheReadCost: cacheReadCost,
      cacheCreationCost: cacheCreationCost
    )
  }

  private static func getPrices(for model: String?) -> (input: Decimal, output: Decimal, cacheRead: Decimal, cacheCreation: Decimal) {
    guard let model = model?.lowercased() else {
      // Default to Opus pricing
      return (opusInputPrice, opusOutputPrice, opusCacheReadPrice, opusCacheCreationPrice)
    }

    if model.contains("opus") {
      return (opusInputPrice, opusOutputPrice, opusCacheReadPrice, opusCacheCreationPrice)
    } else if model.contains("sonnet") {
      return (sonnetInputPrice, sonnetOutputPrice, sonnetCacheReadPrice, sonnetCacheCreationPrice)
    } else if model.contains("haiku") {
      return (haikuInputPrice, haikuOutputPrice, haikuCacheReadPrice, haikuCacheCreationPrice)
    } else {
      // Default to Opus pricing for unknown models
      return (opusInputPrice, opusOutputPrice, opusCacheReadPrice, opusCacheCreationPrice)
    }
  }
}
