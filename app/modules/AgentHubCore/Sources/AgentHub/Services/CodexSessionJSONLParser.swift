//
//  CodexSessionJSONLParser.swift
//  AgentHub
//
//  Parser for Codex session JSONL files with minimal monitoring data.
//

import Foundation

public struct CodexSessionJSONLParser {

  // MARK: - Parsing Results

  public struct ParseResult {
    public var model: String?
    public var lastInputTokens: Int = 0
    public var lastOutputTokens: Int = 0
    public var totalOutputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var messageCount: Int = 0
    public var toolCalls: [String: Int] = [:]
    public var pendingToolUses: [String: PendingToolInfo] = [:]
    public var recentActivities: [ActivityEntry] = []
    public var lastActivityAt: Date?
    public var sessionStartedAt: Date?
    public var currentStatus: SessionStatus = .idle

    public init() {}
  }

  public struct PendingToolInfo {
    public let toolName: String
    public let toolUseId: String
    public let timestamp: Date
  }

  // MARK: - Public API

  public static func parseSessionFile(at path: String, approvalTimeoutSeconds: Int = 0) -> ParseResult {
    var result = ParseResult()

    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
      return result
    }

    for line in content.components(separatedBy: .newlines) where !line.isEmpty {
      if let entry = parseEntry(line) {
        processEntry(entry, into: &result)
      }
    }

    updateCurrentStatus(&result, approvalTimeoutSeconds: approvalTimeoutSeconds)
    return result
  }

  public static func parseNewLines(_ lines: [String], into result: inout ParseResult, approvalTimeoutSeconds: Int = 0) {
    for line in lines where !line.isEmpty {
      if let entry = parseEntry(line) {
        processEntry(entry, into: &result)
      }
    }
    updateCurrentStatus(&result, approvalTimeoutSeconds: approvalTimeoutSeconds)
  }

  // MARK: - Parsing

  private static func parseEntry(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func processEntry(_ entry: [String: Any], into result: inout ParseResult) {
    guard let type = entry["type"] as? String else { return }
    let timestamp = parseTimestamp(entry["timestamp"] as? String)

    if let ts = timestamp {
      if result.sessionStartedAt == nil {
        result.sessionStartedAt = ts
      }
      result.lastActivityAt = ts
    }

    switch type {
    case "session_meta":
      if let payload = entry["payload"] as? [String: Any],
         let tsString = payload["timestamp"] as? String {
        if result.sessionStartedAt == nil {
          result.sessionStartedAt = parseTimestamp(tsString)
        }
      }

    case "turn_context":
      if let payload = entry["payload"] as? [String: Any],
         let model = payload["model"] as? String {
        result.model = model
      }

    case "event_msg":
      guard let payload = entry["payload"] as? [String: Any],
            let eventType = payload["type"] as? String else { return }
      handleEventMessage(type: eventType, payload: payload, timestamp: timestamp, result: &result)

    case "response_item":
      guard let payload = entry["payload"] as? [String: Any],
            let payloadType = payload["type"] as? String else { return }
      handleResponseItem(type: payloadType, payload: payload, timestamp: timestamp, result: &result)

    default:
      break
    }
  }

  private static func handleEventMessage(
    type: String,
    payload: [String: Any],
    timestamp: Date?,
    result: inout ParseResult
  ) {
    switch type {
    case "user_message":
      result.messageCount += 1
      if let message = payload["message"] as? String, !message.isEmpty {
        addActivity(type: .userMessage, description: String(message.prefix(80)), timestamp: timestamp, to: &result)
      }

    case "agent_message":
      result.messageCount += 1
      if let message = payload["message"] as? String, !message.isEmpty {
        addActivity(type: .assistantMessage, description: String(message.prefix(80)), timestamp: timestamp, to: &result)
      }

    case "agent_reasoning":
      addActivity(type: .thinking, description: "Thinking...", timestamp: timestamp, to: &result)

    case "token_count":
      guard let info = payload["info"] as? [String: Any] else { return }
      if let last = info["last_token_usage"] as? [String: Any] {
        let input = (last["input_tokens"] as? Int) ?? 0
        let cached = (last["cached_input_tokens"] as? Int) ?? 0
        let output = (last["output_tokens"] as? Int) ?? 0
        result.lastInputTokens = input + cached
        result.lastOutputTokens = output
        result.totalOutputTokens += output
        result.cacheReadTokens = cached
      } else if let total = info["total_token_usage"] as? [String: Any] {
        let input = (total["input_tokens"] as? Int) ?? 0
        let cached = (total["cached_input_tokens"] as? Int) ?? 0
        let output = (total["output_tokens"] as? Int) ?? 0
        result.lastInputTokens = input + cached
        result.lastOutputTokens = output
        result.totalOutputTokens = output
        result.cacheReadTokens = cached
      }

    default:
      break
    }
  }

  private static func handleResponseItem(
    type: String,
    payload: [String: Any],
    timestamp: Date?,
    result: inout ParseResult
  ) {
    switch type {
    case "function_call":
      guard let name = payload["name"] as? String,
            let callId = payload["call_id"] as? String else { return }
      result.toolCalls[name, default: 0] += 1
      result.pendingToolUses[callId] = PendingToolInfo(toolName: name, toolUseId: callId, timestamp: timestamp ?? Date())
      addActivity(type: .toolUse(name: name), description: name, timestamp: timestamp, to: &result)

    case "function_call_output":
      if let callId = payload["call_id"] as? String {
        let toolName = result.pendingToolUses[callId]?.toolName ?? "tool"
        result.pendingToolUses.removeValue(forKey: callId)
        addActivity(type: .toolResult(name: toolName, success: true), description: "Completed", timestamp: timestamp, to: &result)
      }

    case "custom_tool_call":
      guard let name = payload["name"] as? String else { return }
      let status = payload["status"] as? String
      result.toolCalls[name, default: 0] += 1
      addActivity(type: .toolUse(name: name), description: name, timestamp: timestamp, to: &result)
      if status == "completed" {
        addActivity(type: .toolResult(name: name, success: true), description: "Completed", timestamp: timestamp, to: &result)
      }

    default:
      break
    }
  }

  // MARK: - Status

  public static func updateCurrentStatus(_ result: inout ParseResult, approvalTimeoutSeconds: Int = 0) {
    guard let lastActivity = result.recentActivities.last else {
      result.currentStatus = .idle
      return
    }

    let timeSince = Date().timeIntervalSince(lastActivity.timestamp)

    if timeSince > 300 {
      result.currentStatus = .idle
      return
    }

    switch lastActivity.type {
    case .toolUse(let name):
      result.currentStatus = .executingTool(name: name)
    case .toolResult:
      result.currentStatus = timeSince < 60 ? .thinking : .idle
    case .assistantMessage:
      result.currentStatus = .waitingForUser
    case .userMessage:
      result.currentStatus = timeSince < 60 ? .thinking : .idle
    case .thinking:
      result.currentStatus = timeSince < 30 ? .thinking : .idle
    }
  }

  // MARK: - Helpers

  private static func addActivity(
    type: ActivityType,
    description: String,
    timestamp: Date?,
    to result: inout ParseResult
  ) {
    let entry = ActivityEntry(
      timestamp: timestamp ?? Date(),
      type: type,
      description: description,
      toolInput: nil
    )
    result.recentActivities.append(entry)

    if result.recentActivities.count > 100 {
      result.recentActivities.removeFirst(result.recentActivities.count - 100)
    }
  }

  private static func parseTimestamp(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}

