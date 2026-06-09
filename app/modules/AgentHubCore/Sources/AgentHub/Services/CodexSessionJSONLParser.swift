//
//  CodexSessionJSONLParser.swift
//  AgentHub
//
//  Parser for Codex session JSONL files with minimal monitoring data.
//

import AgentHubGitHub
import AgentHubMCPUI
import Foundation

public struct CodexSessionJSONLParser {

  private static let maxRecentActivities = 100
  private static let maxDetectedResourceLinks = 50
  private static let maxDetectedMCPAppResources = 50
  private static let maxDetectedMCPAppInvocations = 12

  // MARK: - Lightweight Parse Result for Global Stats

  /// Minimal parsing result containing only fields needed for global stats aggregation.
  /// Significantly reduces memory overhead by skipping activities, tool calls, timestamps, and status.
  public struct GlobalStatsParseResult: Sendable {
    public var model: String?
    public var totalInputTokens: Int = 0
    public var totalOutputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var messageCount: Int = 0

    public init() {}
  }

  /// Minimal parsing result for launch restoration and targeted session loading.
  /// Skips activity, tool state, resource detection, and status computation.
  public struct SessionSummaryParseResult: Sendable {
    public var messageCount: Int = 0
    public var lastActivityAt: Date?
    public var firstUserMessage: String?
    public var lastUserMessage: String?

    public init() {}
  }

  // MARK: - Parsing Results

  public struct ParseResult: Sendable {
    public var model: String?
    public var lastInputTokens: Int = 0
    public var lastOutputTokens: Int = 0
    public var totalInputTokens: Int = 0  // Cumulative input tokens from total_token_usage
    public var totalOutputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var messageCount: Int = 0
    public var pendingToolUses: [String: PendingToolInfo] = [:]
    public var recentActivities: [ActivityEntry] = []
    public var lastActivityAt: Date?
    public var sessionStartedAt: Date?
    public var currentStatus: SessionStatus = .idle
    public var hasMermaidContent: Bool = false
    public var detectedResourceLinks: [ResourceLink] = []
    public var detectedMCPAppResources: [MCPAppResourceDescriptor] = []
    public var detectedMCPAppInvocations: [MCPAppInvocation] = []
    public var detectedLocalhostURL: URL?

    public init() {}
  }

  public struct PendingToolInfo: Sendable {
    public let toolName: String
    public let toolUseId: String
    public let timestamp: Date
  }

  // MARK: - Public API

  /// Lightweight parsing for global stats aggregation.
  /// Skips activity tracking, tool call tracking, timestamp parsing, and status computation.
  /// Memory efficient: only extracts model, tokens, and message count.
  public static func parseForGlobalStats(at path: String) -> GlobalStatsParseResult {
    var result = GlobalStatsParseResult()

    guard let handle = FileHandle(forReadingAtPath: path) else {
      return result
    }
    defer { try? handle.close() }

    guard let data = try? handle.readToEnd(),
          let content = String(data: data, encoding: .utf8) else {
      return result
    }

    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let lineData = line.data(using: .utf8),
            let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            let type = entry["type"] as? String else { continue }

      switch type {
      case "turn_context":
        if let payload = entry["payload"] as? [String: Any],
           let model = payload["model"] as? String {
          result.model = model
        }

      case "event_msg":
        guard let payload = entry["payload"] as? [String: Any],
              let eventType = payload["type"] as? String else { continue }

        if eventType == "user_message" || eventType == "agent_message" {
          result.messageCount += 1
        } else if eventType == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] {
          let input = (total["input_tokens"] as? Int) ?? 0
          let cached = (total["cached_input_tokens"] as? Int) ?? 0
          let output = (total["output_tokens"] as? Int) ?? 0
          result.totalInputTokens = input + cached
          result.totalOutputTokens = output
          result.cacheReadTokens = cached
        }

      default:
        break
      }
    }

    return result
  }

  public static func parseSessionSummaryFile(at path: String) -> SessionSummaryParseResult {
    var result = SessionSummaryParseResult()

    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
      return result
    }

    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let lineData = line.data(using: .utf8),
            let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
        continue
      }
      processSummaryEntry(entry, into: &result)
    }

    return result
  }

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

  private static func processSummaryEntry(_ entry: [String: Any], into result: inout SessionSummaryParseResult) {
    if let timestamp = CodexTimestampParser.parse(entry["timestamp"] as? String) {
      result.lastActivityAt = timestamp
    }

    guard let type = entry["type"] as? String,
          type == "event_msg",
          let payload = entry["payload"] as? [String: Any],
          let eventType = payload["type"] as? String else {
      return
    }

    switch eventType {
    case "user_message":
      result.messageCount += 1
      guard let message = payload["message"] as? String else { return }
      let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty else { return }
      let preview = String(cleaned.prefix(500))
      if result.firstUserMessage == nil {
        result.firstUserMessage = preview
      }
      result.lastUserMessage = preview

    case "agent_message":
      result.messageCount += 1

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
        if message.contains("```mermaid") { result.hasMermaidContent = true }
        appendResourceLinks(extractResourceLinks(from: message, timestamp: timestamp), to: &result)
        appendMCPAppResources(MCPAppResourceExtractor.extract(from: message), to: &result)
        if let localhostURL = extractLocalhostURLFromText(message) {
          result.detectedLocalhostURL = localhostURL
        }
        addActivity(type: .assistantMessage, description: String(message.prefix(80)), timestamp: timestamp, to: &result)
      }

    case "agent_reasoning":
      addActivity(type: .thinking, description: "Thinking...", timestamp: timestamp, to: &result)

    case "token_count":
      guard let info = payload["info"] as? [String: Any] else { return }
      // Use total_token_usage for cumulative session totals (used by global stats)
      if let total = info["total_token_usage"] as? [String: Any] {
        let input = (total["input_tokens"] as? Int) ?? 0
        let cached = (total["cached_input_tokens"] as? Int) ?? 0
        let output = (total["output_tokens"] as? Int) ?? 0
        // Store the latest totals (the API accumulates these values)
        result.totalInputTokens = input + cached
        result.totalOutputTokens = output
        result.cacheReadTokens = cached
      }
      // Use last_token_usage for real-time monitoring
      if let last = info["last_token_usage"] as? [String: Any] {
        let input = (last["input_tokens"] as? Int) ?? 0
        let cached = (last["cached_input_tokens"] as? Int) ?? 0
        let output = (last["output_tokens"] as? Int) ?? 0
        result.lastInputTokens = input + cached
        result.lastOutputTokens = output
      }

    case "mcp_tool_call_end":
      appendResourceLinks(extractResourceLinks(fromJSONValue: payload, timestamp: timestamp), to: &result)
      appendMCPAppResources(MCPAppResourceExtractor.extract(from: payload), to: &result)
      captureMCPAppInvocation(from: payload, into: &result)

    default:
      break
    }
  }

  /// Codex reports an MCP tool call as a single `mcp_tool_call_end` event carrying
  /// `invocation.{server,tool,arguments}` and `result` (`Ok`/`Err`-wrapped). Unlike
  /// Claude, no tool_use/tool_result correlation is needed — it's all in one event.
  private static func captureMCPAppInvocation(
    from payload: [String: Any],
    into result: inout ParseResult
  ) {
    guard let invocation = payload["invocation"] as? [String: Any],
          let server = invocation["server"] as? String,
          let tool = invocation["tool"] as? String else {
      return
    }
    let callId = (payload["call_id"] as? String) ?? "\(server)|\(tool)"
    let arguments = invocation["arguments"].map { AgentHubMCPUIJSONValue(any: $0) }

    // Unwrap Codex's Ok/Err result envelope into the raw MCP result object.
    var resultValue: AgentHubMCPUIJSONValue?
    if let resultDict = payload["result"] as? [String: Any] {
      if let ok = resultDict["Ok"] {
        resultValue = AgentHubMCPUIJSONValue(any: ok)
      } else if let err = resultDict["Err"] {
        resultValue = AgentHubMCPUIJSONValue(any: err)
      } else {
        resultValue = AgentHubMCPUIJSONValue(any: resultDict)
      }
    }

    appendMCPAppInvocation(
      MCPAppInvocation(
        id: callId,
        serverName: server,
        toolName: tool,
        arguments: arguments,
        result: resultValue
      ),
      into: &result
    )
  }

  private static func appendMCPAppInvocation(
    _ invocation: MCPAppInvocation,
    into result: inout ParseResult
  ) {
    result.detectedMCPAppInvocations.removeAll { $0.id == invocation.id }
    result.detectedMCPAppInvocations.append(invocation)
    if result.detectedMCPAppInvocations.count > maxDetectedMCPAppInvocations {
      result.detectedMCPAppInvocations.removeFirst(
        result.detectedMCPAppInvocations.count - maxDetectedMCPAppInvocations
      )
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
      result.pendingToolUses[callId] = PendingToolInfo(toolName: name, toolUseId: callId, timestamp: timestamp ?? Date())
      addActivity(type: .toolUse(name: name), description: name, timestamp: timestamp, to: &result)

    case "function_call_output":
      if let callId = payload["call_id"] as? String {
        let toolName = result.pendingToolUses[callId]?.toolName ?? "tool"
        result.pendingToolUses.removeValue(forKey: callId)
        addActivity(type: .toolResult(name: toolName, success: true), description: "Completed", timestamp: timestamp, to: &result)
        // Extract localhost URLs from tool output
        if let output = payload["output"] as? String,
           let localhostURL = extractLocalhostURLFromText(output) {
          result.detectedLocalhostURL = localhostURL
        }
        appendResourceLinks(extractResourceLinks(fromJSONValue: payload, timestamp: timestamp), to: &result)
        appendMCPAppResources(MCPAppResourceExtractor.extract(from: payload), to: &result)
      }

    case "custom_tool_call":
      guard let name = payload["name"] as? String else { return }
      let status = payload["status"] as? String
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

    if result.recentActivities.count > maxRecentActivities {
      result.recentActivities.removeFirst(result.recentActivities.count - maxRecentActivities)
    }
  }

  private static func appendResourceLinks(_ links: [ResourceLink], to result: inout ParseResult) {
    for link in links where !result.detectedResourceLinks.contains(where: { $0.url == link.url }) {
      result.detectedResourceLinks.append(link)
    }

    if result.detectedResourceLinks.count > maxDetectedResourceLinks {
      result.detectedResourceLinks.removeFirst(result.detectedResourceLinks.count - maxDetectedResourceLinks)
    }
  }

  private static func appendMCPAppResources(
    _ descriptors: [MCPAppResourceDescriptor],
    to result: inout ParseResult
  ) {
    for descriptor in descriptors where !result.detectedMCPAppResources.contains(where: {
      $0.serverName == descriptor.serverName && $0.uri == descriptor.uri
    }) {
      result.detectedMCPAppResources.append(descriptor)
    }

    if result.detectedMCPAppResources.count > maxDetectedMCPAppResources {
      result.detectedMCPAppResources.removeFirst(
        result.detectedMCPAppResources.count - maxDetectedMCPAppResources
      )
    }
  }

  private static func extractResourceLinks(fromJSONValue value: Any, timestamp: Date?) -> [ResourceLink] {
    switch value {
    case let string as String:
      return prioritizedResourceLinks(from: string, timestamp: timestamp)
    case let array as [Any]:
      return prioritizingPullRequestLinks(
        array.flatMap { extractResourceLinks(fromJSONValue: $0, timestamp: timestamp) }
      )
    case let dictionary as [String: Any]:
      return prioritizingPullRequestLinks(
        dictionary.values.flatMap { extractResourceLinks(fromJSONValue: $0, timestamp: timestamp) }
      )
    default:
      return []
    }
  }

  private static func extractResourceLinks(from text: String, timestamp: Date?) -> [ResourceLink] {
    guard let regex = try? NSRegularExpression(
      pattern: "https?://[^\\s)\\]>\"'`]+",
      options: []
    ) else { return [] }

    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, options: [], range: range)

    var links: [ResourceLink] = []
    for match in matches {
      guard let matchRange = Range(match.range, in: text) else { continue }
      var urlString = String(text[matchRange])
      while let last = urlString.last, [".", ",", ";", ":"].contains(String(last)) {
        urlString.removeLast()
      }
      links.append(ResourceLink(url: urlString, timestamp: timestamp ?? Date()))
    }
    return links
  }

  private static func prioritizedResourceLinks(from text: String, timestamp: Date?) -> [ResourceLink] {
    let links = extractResourceLinks(from: text, timestamp: timestamp)
    return prioritizingPullRequestLinks(links)
  }

  private static func prioritizingPullRequestLinks(_ links: [ResourceLink]) -> [ResourceLink] {
    let pullRequestLinks = links.filter { GitHubPullRequestURLReference(urlString: $0.url) != nil }
    return pullRequestLinks.isEmpty ? links : pullRequestLinks
  }

  // MARK: - Localhost URL Extraction

  private static func extractLocalhostURLFromText(_ text: String) -> URL? {
    LocalhostURLNormalizer.extractFirstURL(from: text)
  }

  private static func parseTimestamp(_ string: String?) -> Date? {
    CodexTimestampParser.parse(string)
  }
}
