//
//  StreamJSONTypes.swift
//  AgentHub
//
//  Lightweight Codable types for parsing `claude -p --output-format stream-json` output.
//  Replaces ClaudeCodeSDK / SwiftAnthropic types with zero external dependencies.
//

import Foundation

// MARK: - Top-Level Chunk

/// A single JSON object from Claude CLI's stream-json output.
/// Each line of stdout is one of these discriminated by the `"type"` field.
public enum StreamJSONChunk {
  case system(CLIInitSystemMessage)
  case assistant(CLIAssistantMessage)
  case user(CLIUserMessage)
  case result(CLIResultMessage)
}

extension StreamJSONChunk: Decodable {
  private enum CodingKeys: String, CodingKey {
    case type
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "system":
      self = .system(try CLIInitSystemMessage(from: decoder))
    case "assistant":
      self = .assistant(try CLIAssistantMessage(from: decoder))
    case "user":
      self = .user(try CLIUserMessage(from: decoder))
    case "result":
      self = .result(try CLIResultMessage(from: decoder))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown chunk type: \(type)"
      )
    }
  }
}

// MARK: - System Message

public struct CLIInitSystemMessage: Decodable {
  public let type: String
  public let subtype: String?
  public let sessionId: String?
  public let tools: [String]?
  public let mcpServers: [CLIMCPServer]?

  public struct CLIMCPServer: Decodable {
    public let name: String
    public let status: String?
  }

  private enum CodingKeys: String, CodingKey {
    case type, subtype, sessionId = "session_id", tools, mcpServers = "mcp_servers"
  }
}

// MARK: - Assistant Message

public struct CLIAssistantMessage: Decodable {
  public let type: String
  public let sessionId: String?
  public let message: CLIMessageContent

  private enum CodingKeys: String, CodingKey {
    case type, sessionId = "session_id", message
  }
}

public struct CLIMessageContent: Decodable {
  public let role: String?
  public let content: [CLIContentBlock]
}

// MARK: - Content Block

public enum CLIContentBlock {
  case text(String)
  case toolUse(CLIToolUse)
  case toolResult(CLIToolResult)
  case thinking(CLIThinking)
  case unknown
}

extension CLIContentBlock: Decodable {
  private enum CodingKeys: String, CodingKey {
    case type, text, id, name, input, thinking, signature
    case toolUseId = "tool_use_id"
    case content, isError = "is_error"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "text":
      let text = try container.decode(String.self, forKey: .text)
      self = .text(text)

    case "tool_use":
      let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
      let name = try container.decode(String.self, forKey: .name)
      let input = try container.decodeIfPresent([String: DynamicJSONValue].self, forKey: .input) ?? [:]
      self = .toolUse(CLIToolUse(id: id, name: name, input: input))

    case "tool_result":
      let toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
      let isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
      let content = try container.decode(CLIToolResultContent.self, forKey: .content)
      self = .toolResult(CLIToolResult(toolUseId: toolUseId, isError: isError, content: content))

    case "thinking":
      let thinking = try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""
      let signature = try container.decodeIfPresent(String.self, forKey: .signature)
      self = .thinking(CLIThinking(thinking: thinking, signature: signature))

    default:
      self = .unknown
    }
  }
}

// MARK: - Tool Use

public struct CLIToolUse {
  public let id: String
  public let name: String
  public let input: [String: DynamicJSONValue]
}

// MARK: - Tool Result

public struct CLIToolResult {
  public let toolUseId: String?
  public let isError: Bool?
  public let content: CLIToolResultContent
}

public enum CLIToolResultContent {
  case string(String)
  case items([CLIContentItem])
}

extension CLIToolResultContent: Decodable {
  public init(from decoder: Decoder) throws {
    // Try string first
    if let container = try? decoder.singleValueContainer(),
       let str = try? container.decode(String.self) {
      self = .string(str)
      return
    }

    // Try array of items
    if let items = try? [CLIContentItem](from: decoder) {
      self = .items(items)
      return
    }

    self = .string("")
  }
}

public struct CLIContentItem: Decodable {
  public let type: String?
  public let text: String?
}

// MARK: - Thinking

public struct CLIThinking {
  public let thinking: String
  public let signature: String?
}

// MARK: - User Message

public struct CLIUserMessage: Decodable {
  public let type: String
  public let sessionId: String?
  public let message: CLIUserMessageContent

  private enum CodingKeys: String, CodingKey {
    case type, sessionId = "session_id", message
  }
}

public struct CLIUserMessageContent: Decodable {
  public let role: String?
  public let content: [CLIContentBlock]
}

// MARK: - Result Message

public struct CLIResultMessage: Decodable {
  public let type: String
  public let subtype: String?
  public let totalCostUsd: Double?
  public let durationMs: Int?
  public let durationApiMs: Int?
  public let isError: Bool?
  public let numTurns: Int?
  public let result: String?
  public let sessionId: String?

  private enum CodingKeys: String, CodingKey {
    case type, subtype, result
    case totalCostUsd = "total_cost_usd"
    case durationMs = "duration_ms"
    case durationApiMs = "duration_api_ms"
    case isError = "is_error"
    case numTurns = "num_turns"
    case sessionId = "session_id"
  }
}

// MARK: - Dynamic JSON Value

/// A recursive type representing arbitrary JSON values.
/// Replaces `MessageResponse.Content.DynamicContent` from SwiftAnthropic.
public enum DynamicJSONValue: Sendable {
  case string(String)
  case integer(Int)
  case double(Double)
  case bool(Bool)
  case dictionary([String: DynamicJSONValue])
  case array([DynamicJSONValue])
  case null
}

extension DynamicJSONValue: Decodable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let int = try? container.decode(Int.self) {
      self = .integer(int)
    } else if let double = try? container.decode(Double.self) {
      self = .double(double)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([DynamicJSONValue].self) {
      self = .array(array)
    } else if let dict = try? container.decode([String: DynamicJSONValue].self) {
      self = .dictionary(dict)
    } else {
      self = .null
    }
  }
}

extension DynamicJSONValue: Encodable {
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .dictionary(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

extension Dictionary where Key == String, Value == DynamicJSONValue {
  /// Returns a human-readable summary of the dictionary contents.
  func formattedDescription() -> String {
    self.compactMap { key, value -> String? in
      let formatted = value.stringValue
      guard !formatted.isEmpty else { return nil }
      return "\(key): \(formatted)"
    }.joined(separator: ", ")
  }
}

extension DynamicJSONValue {
  /// Compact string representation for display purposes.
  public var stringValue: String {
    switch self {
    case .string(let s): return s
    case .integer(let i): return String(i)
    case .double(let d): return String(d)
    case .bool(let b): return String(b)
    case .null: return "null"
    case .array(let arr):
      return "[\(arr.map(\.stringValue).joined(separator: ", "))]"
    case .dictionary(let dict):
      return dict.formattedDescription()
    }
  }
}

// MARK: - Process Error

/// Errors from the CLI process service.
public enum CLIProcessError: LocalizedError {
  case notInstalled(String)
  case executionFailed(String)
  case timeout(TimeInterval)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .notInstalled(let command):
      return "Could not find '\(command)' command. Please ensure Claude Code CLI is installed."
    case .executionFailed(let message):
      return "CLI process failed: \(message)"
    case .timeout(let seconds):
      return "Request timed out after \(Int(seconds)) seconds"
    case .cancelled:
      return "Request was cancelled"
    }
  }
}
