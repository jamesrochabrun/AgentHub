//
//  SessionJSONLParser.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import Foundation

// MARK: - SessionJSONLParser

/// Parser for session JSONL files that extracts monitoring data
public struct SessionJSONLParser {

  // MARK: - Entry Types

  /// Raw entry from session JSONL file
  public struct SessionEntry: Decodable {
    let type: String
    let timestamp: String?
    let uuid: String?
    let message: MessageContent?
    let costUSD: Double?
    let durationMs: Int?
  }

  /// Message content within an entry
  public struct MessageContent: Decodable {
    let role: String?
    let model: String?
    let content: [ContentBlock]?
    let usage: UsageInfo?
  }

  /// Content block (text, tool_use, tool_result, thinking)
  public struct ContentBlock: Decodable {
    let type: String
    let id: String?
    let name: String?
    let input: AnyCodable?
    let toolUseId: String?
    let content: AnyCodable?
    let text: String?

    private enum CodingKeys: String, CodingKey {
      case type, id, name, input
      case toolUseId = "tool_use_id"
      case content, text
    }
  }

  /// Token usage information
  public struct UsageInfo: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    private enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
      case cacheReadInputTokens = "cache_read_input_tokens"
      case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
  }

  // MARK: - Parsing Results

  /// Result of parsing a session file
  public struct ParseResult {
    public var model: String?
    // Context window tracking: use LAST inputTokens (each API call sends full conversation)
    public var lastInputTokens: Int = 0
    public var lastOutputTokens: Int = 0
    // Cost calculation: accumulate output tokens
    public var totalOutputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var messageCount: Int = 0
    public var toolCalls: [String: Int] = [:]
    public var pendingToolUses: [String: PendingToolInfo] = [:]  // toolUseId -> info
    public var recentActivities: [ActivityEntry] = []
    public var lastActivityAt: Date?
    public var sessionStartedAt: Date?
    public var currentStatus: SessionStatus = .idle
    public var gitBranch: String?

    public init() {}
  }

  /// Info about a pending tool use
  public struct PendingToolInfo {
    public let toolName: String
    public let toolUseId: String
    public let timestamp: Date
    public let input: String?
  }

  // MARK: - Public API

  /// Parse an entire session file and return aggregated state
  /// - Parameters:
  ///   - path: Path to the session JSONL file
  ///   - approvalTimeoutSeconds: Seconds to wait before considering a tool as awaiting approval (default: 5)
  public static func parseSessionFile(at path: String, approvalTimeoutSeconds: Int = 5) -> ParseResult {
    print("[SessionJSONLParser] parseSessionFile: \(path)")
    var result = ParseResult()

    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
      print("[SessionJSONLParser] Failed to read file")
      return result
    }

    let lines = content.components(separatedBy: .newlines)
    print("[SessionJSONLParser] Found \(lines.count) lines")

    for line in lines where !line.isEmpty {
      if let entry = parseEntry(line) {
        processEntry(entry, into: &result)
      }
    }

    // Determine current status from pending tools
    updateCurrentStatus(&result, approvalTimeoutSeconds: approvalTimeoutSeconds)

    print("[SessionJSONLParser] Result: \(result.messageCount) msgs, \(result.lastInputTokens) input, \(result.totalOutputTokens) total output, \(result.pendingToolUses.count) pending")
    return result
  }

  /// Parse new lines from a session file (for incremental updates)
  /// - Parameters:
  ///   - lines: New lines to parse
  ///   - result: Parse result to update
  ///   - approvalTimeoutSeconds: Seconds to wait before considering a tool as awaiting approval (default: 5)
  public static func parseNewLines(_ lines: [String], into result: inout ParseResult, approvalTimeoutSeconds: Int = 5) {
    for line in lines where !line.isEmpty {
      if let entry = parseEntry(line) {
        processEntry(entry, into: &result)
      }
    }
    updateCurrentStatus(&result, approvalTimeoutSeconds: approvalTimeoutSeconds)
  }

  /// Parse a single JSONL line
  public static func parseEntry(_ line: String) -> SessionEntry? {
    guard let data = line.data(using: .utf8) else { return nil }

    do {
      let decoder = JSONDecoder()
      return try decoder.decode(SessionEntry.self, from: data)
    } catch {
      // Many lines may not match our expected format, that's OK
      return nil
    }
  }

  // MARK: - Private Processing

  private static func processEntry(_ entry: SessionEntry, into result: inout ParseResult) {
    // Parse timestamp
    let timestamp = parseTimestamp(entry.timestamp)

    // Track first/last activity
    if let ts = timestamp {
      if result.sessionStartedAt == nil {
        result.sessionStartedAt = ts
      }
      result.lastActivityAt = ts
    }

    // Process based on type
    switch entry.type {
    case "user":
      result.messageCount += 1

      // Process content blocks - tool_results come in user messages!
      if let blocks = entry.message?.content {
        processContentBlocks(blocks, timestamp: timestamp, into: &result)
      }

      // Only add user message activity if there's actual text (not just tool results)
      let textPreview = extractTextPreview(from: entry.message?.content)
      if !textPreview.isEmpty {
        addActivity(
          type: .userMessage,
          description: textPreview,
          timestamp: timestamp,
          to: &result
        )
      }

    case "assistant":
      result.messageCount += 1

      // Extract model
      if let model = entry.message?.model {
        result.model = model
      }

      // Extract usage
      if let usage = entry.message?.usage {
        // For context window: total = input + cache_read + cache_creation
        // (each API call sends full conversation, cache tokens are part of context)
        let inputTokens = usage.inputTokens ?? 0
        let cacheRead = usage.cacheReadInputTokens ?? 0
        let cacheCreation = usage.cacheCreationInputTokens ?? 0
        result.lastInputTokens = inputTokens + cacheRead + cacheCreation
        result.lastOutputTokens = usage.outputTokens ?? 0
        // For cost calculation: accumulate output tokens
        result.totalOutputTokens += usage.outputTokens ?? 0
        result.cacheReadTokens += cacheRead
        result.cacheCreationTokens += cacheCreation
      }

      // Process content blocks
      if let blocks = entry.message?.content {
        processContentBlocks(blocks, timestamp: timestamp, into: &result)
      }

    case "summary":
      // Summary entries may contain git branch info
      break

    default:
      break
    }
  }

  private static func processContentBlocks(
    _ blocks: [ContentBlock],
    timestamp: Date?,
    into result: inout ParseResult
  ) {
    for block in blocks {
      switch block.type {
      case "tool_use":
        if let name = block.name, let id = block.id {
          // Track tool call count
          result.toolCalls[name, default: 0] += 1

          // Add to pending (will be removed when we see tool_result)
          let inputPreview = extractInputPreview(block.input)
          result.pendingToolUses[id] = PendingToolInfo(
            toolName: name,
            toolUseId: id,
            timestamp: timestamp ?? Date(),
            input: inputPreview
          )

          // Extract full input for code-changing tools
          let codeChangeInput = extractCodeChangeInput(name: name, input: block.input)

          addActivity(
            type: .toolUse(name: name),
            description: inputPreview ?? name,
            timestamp: timestamp,
            codeChangeInput: codeChangeInput,
            to: &result
          )
        }

      case "tool_result":
        if let toolUseId = block.toolUseId {
          // Find tool name before removing from pending
          let toolName = result.pendingToolUses[toolUseId]?.toolName ?? "unknown"

          // Remove from pending - tool completed
          result.pendingToolUses.removeValue(forKey: toolUseId)
          let success = !isErrorResult(block.content)

          addActivity(
            type: .toolResult(name: toolName, success: success),
            description: success ? "Completed" : "Error",
            timestamp: timestamp,
            to: &result
          )
        }

      case "thinking":
        addActivity(
          type: .thinking,
          description: "Thinking...",
          timestamp: timestamp,
          to: &result
        )

      case "text":
        addActivity(
          type: .assistantMessage,
          description: block.text?.prefix(50).description ?? "",
          timestamp: timestamp,
          to: &result
        )

      default:
        break
      }
    }
  }

  /// Re-evaluate current status based on time elapsed since last activity
  /// - Parameters:
  ///   - result: The parse result to update
  ///   - approvalTimeoutSeconds: Seconds to wait before considering a tool as awaiting approval (default: 5)
  public static func updateCurrentStatus(_ result: inout ParseResult, approvalTimeoutSeconds: Int = 5) {
    // State machine with timeout-based detection
    // Based on Kyle Mathews' claude-code-ui approach
    guard let lastActivity = result.recentActivities.last else {
      result.currentStatus = .idle
      return
    }

    let timeSince = Date().timeIntervalSince(lastActivity.timestamp)

    // Global idle timeout: 5 minutes
    if timeSince > 300 {
      result.currentStatus = .idle
      return
    }

    switch lastActivity.type {
    case .toolUse(let name):
      // Task tool runs in background, doesn't need approval
      if name == "Task" {
        result.currentStatus = .executingTool(name: name)
      } else if timeSince > Double(approvalTimeoutSeconds) {
        // After configured seconds without result, probably needs approval
        result.currentStatus = .awaitingApproval(tool: name)
      } else {
        result.currentStatus = .executingTool(name: name)
      }

    case .toolResult:
      // Tool completed - Claude should be processing
      if timeSince < 60 {
        result.currentStatus = .thinking
      } else {
        result.currentStatus = .idle
      }

    case .assistantMessage:
      // Claude sent text response - waiting for user input
      result.currentStatus = .waitingForUser

    case .userMessage:
      // User sent message - Claude should be working
      if timeSince < 60 {
        result.currentStatus = .thinking
      } else {
        result.currentStatus = .idle
      }

    case .thinking:
      if timeSince < 30 {
        result.currentStatus = .thinking
      } else {
        result.currentStatus = .idle
      }
    }
  }

  private static func addActivity(
    type: ActivityType,
    description: String,
    timestamp: Date?,
    codeChangeInput: CodeChangeInput? = nil,
    to result: inout ParseResult
  ) {
    let entry = ActivityEntry(
      timestamp: timestamp ?? Date(),
      type: type,
      description: description,
      toolInput: codeChangeInput
    )

    result.recentActivities.append(entry)

    // Keep more activities for code change tracking (was 20, now 100)
    if result.recentActivities.count > 100 {
      result.recentActivities.removeFirst(result.recentActivities.count - 100)
    }
  }

  /// Extract full input parameters for code-changing tools (Edit, Write, MultiEdit)
  private static func extractCodeChangeInput(name: String, input: AnyCodable?) -> CodeChangeInput? {
    guard let input = input,
          let dict = input.value as? [String: Any],
          let filePath = dict["file_path"] as? String else {
      return nil
    }

    switch name {
    case "Edit":
      return CodeChangeInput(
        toolType: .edit,
        filePath: filePath,
        oldString: dict["old_string"] as? String,
        newString: dict["new_string"] as? String,
        replaceAll: dict["replace_all"] as? Bool
      )

    case "Write":
      return CodeChangeInput(
        toolType: .write,
        filePath: filePath,
        newString: dict["content"] as? String
      )

    case "MultiEdit":
      var editsArray: [[String: String]]? = nil
      if let edits = dict["edits"] as? [[String: Any]] {
        editsArray = edits.compactMap { edit in
          var result = [String: String]()
          if let oldStr = edit["old_string"] as? String { result["old_string"] = oldStr }
          if let newStr = edit["new_string"] as? String { result["new_string"] = newStr }
          if let replaceAll = edit["replace_all"] as? Bool { result["replace_all"] = String(replaceAll) }
          return result.isEmpty ? nil : result
        }
      }
      return CodeChangeInput(
        toolType: .multiEdit,
        filePath: filePath,
        edits: editsArray
      )

    default:
      return nil
    }
  }

  // MARK: - Helpers

  private static func parseTimestamp(_ string: String?) -> Date? {
    guard let string = string else { return nil }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    if let date = formatter.date(from: string) {
      return date
    }

    // Try without fractional seconds
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }

  private static func extractTextPreview(from blocks: [ContentBlock]?) -> String {
    guard let blocks = blocks else { return "" }

    for block in blocks {
      if block.type == "text", let text = block.text {
        let preview = text.prefix(80)
        return String(preview)
      }
    }
    return ""
  }

  private static func extractInputPreview(_ input: AnyCodable?) -> String? {
    guard let input = input else { return nil }

    // Try to extract meaningful info from tool input
    if let dict = input.value as? [String: Any] {
      // Common patterns
      if let path = dict["file_path"] as? String {
        return URL(fileURLWithPath: path).lastPathComponent
      }
      if let command = dict["command"] as? String {
        return String(command.prefix(50))
      }
      if let pattern = dict["pattern"] as? String {
        return pattern
      }
      if let query = dict["query"] as? String {
        return String(query.prefix(50))
      }
    }

    return nil
  }

  private static func isErrorResult(_ content: AnyCodable?) -> Bool {
    guard let content = content else { return false }

    if let str = content.value as? String {
      return str.lowercased().contains("error")
    }

    if let arr = content.value as? [[String: Any]] {
      for item in arr {
        if let text = item["text"] as? String,
           text.lowercased().contains("error") {
          return true
        }
      }
    }

    return false
  }
}

// MARK: - AnyCodable

/// Type-erased Codable wrapper for arbitrary JSON values
public struct AnyCodable: Decodable {
  public let value: Any

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self.value = NSNull()
    } else if let bool = try? container.decode(Bool.self) {
      self.value = bool
    } else if let int = try? container.decode(Int.self) {
      self.value = int
    } else if let double = try? container.decode(Double.self) {
      self.value = double
    } else if let string = try? container.decode(String.self) {
      self.value = string
    } else if let array = try? container.decode([AnyCodable].self) {
      self.value = array.map { $0.value }
    } else if let dictionary = try? container.decode([String: AnyCodable].self) {
      self.value = dictionary.mapValues { $0.value }
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unable to decode value"
      )
    }
  }
}
