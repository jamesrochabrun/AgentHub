//
//  StreamJSONTypes.swift
//  ClaudeCodeClient
//

import Foundation

public enum StreamJSONChunk: Sendable {
  case system(CLISystemMessage)
  case assistant(CLIAssistantMessage)
  case user(CLIUserMessage)
  case result(CLIResultMessage)
  case unknown(CLIUnknownChunk)
}

public enum StreamJSONChunkType: Sendable, Equatable {
  case system
  case assistant
  case user
  case result
  case unknown(String)
}

public enum CLIMessageRole: Sendable, Equatable {
  case system
  case user
  case assistant
  case unknown(String)
}

public enum CLIContentBlockType: Sendable, Equatable {
  case text
  case toolUse
  case toolResult
  case thinking
  case unknown(String)
}

public enum CLIContentItemType: Sendable, Equatable {
  case text
  case unknown(String)
}

public enum CLISystemSubtype: Sendable, Equatable {
  case initialization
  case unknown(String)
}

public enum CLIResultSubtype: Sendable, Equatable {
  case success
  case errorMaxTurns
  case unknown(String)
}

extension CLIResultSubtype: Decodable {
  public init(from decoder: Decoder) throws {
    let rawValue = try decoder.singleValueContainer().decode(String.self)
    switch rawValue {
    case "success":
      self = .success
    case "error_max_turns":
      self = .errorMaxTurns
    default:
      self = .unknown(rawValue)
    }
  }
}

extension StreamJSONChunkType: Decodable {
  public init(from decoder: Decoder) throws {
    let rawValue = try decoder.singleValueContainer().decode(String.self)
    switch rawValue {
    case "system":
      self = .system
    case "assistant":
      self = .assistant
    case "user":
      self = .user
    case "result":
      self = .result
    default:
      self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .system:
      return "system"
    case .assistant:
      return "assistant"
    case .user:
      return "user"
    case .result:
      return "result"
    case .unknown(let rawValue):
      return rawValue
    }
  }
}

extension CLIMessageRole: Decodable {
  public init(from decoder: Decoder) throws {
    let rawValue = try decoder.singleValueContainer().decode(String.self)
    switch rawValue {
    case "system":
      self = .system
    case "user":
      self = .user
    case "assistant":
      self = .assistant
    default:
      self = .unknown(rawValue)
    }
  }
}

extension CLIContentBlockType: Decodable {
  public init(from decoder: Decoder) throws {
    let rawValue = try decoder.singleValueContainer().decode(String.self)
    switch rawValue {
    case "text":
      self = .text
    case "tool_use":
      self = .toolUse
    case "tool_result":
      self = .toolResult
    case "thinking":
      self = .thinking
    default:
      self = .unknown(rawValue)
    }
  }
}

extension CLIContentItemType: Decodable {
  public init(from decoder: Decoder) throws {
    let rawValue = try decoder.singleValueContainer().decode(String.self)
    switch rawValue {
    case "text":
      self = .text
    default:
      self = .unknown(rawValue)
    }
  }
}

extension CLISystemSubtype: Decodable {
  public init(from decoder: Decoder) throws {
    let rawValue = try decoder.singleValueContainer().decode(String.self)
    switch rawValue {
    case "init":
      self = .initialization
    default:
      self = .unknown(rawValue)
    }
  }
}

extension StreamJSONChunk: Decodable {
  private enum CodingKeys: String, CodingKey {
    case type
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(StreamJSONChunkType.self, forKey: .type)

    switch type {
    case .system:
      self = .system(try CLISystemMessage(from: decoder))
    case .assistant:
      self = .assistant(try CLIAssistantMessage(from: decoder))
    case .user:
      self = .user(try CLIUserMessage(from: decoder))
    case .result:
      self = .result(try CLIResultMessage(from: decoder))
    case .unknown(let rawValue):
      self = .unknown(CLIUnknownChunk(type: rawValue))
    }
  }
}

public struct CLIUnknownChunk: Sendable {
  public let type: String

  public init(type: String) {
    self.type = type
  }
}

public struct CLISystemMessage: Decodable, Sendable {
  public let type: StreamJSONChunkType
  public let subtype: CLISystemSubtype?
  public let sessionId: String?
  public let tools: [String]?
  public let mcpServers: [CLIMCPServer]?

  public struct CLIMCPServer: Decodable, Sendable {
    public let name: String
    public let status: String?
  }

  private enum CodingKeys: String, CodingKey {
    case type, subtype, sessionId = "session_id", tools, mcpServers = "mcp_servers"
  }
}

public struct CLIAssistantMessage: Decodable, Sendable {
  public let type: StreamJSONChunkType
  public let sessionId: String?
  public let message: CLIMessageContent

  private enum CodingKeys: String, CodingKey {
    case type, sessionId = "session_id", message
  }
}

public struct CLIMessageContent: Decodable, Sendable {
  public let role: CLIMessageRole?
  public let content: [CLIContentBlock]
}

public enum CLIContentBlock: Sendable {
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
    let type = try container.decode(CLIContentBlockType.self, forKey: .type)

    switch type {
    case .text:
      self = .text(try container.decode(String.self, forKey: .text))
    case .toolUse:
      let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
      let name = try container.decode(String.self, forKey: .name)
      let input = try container.decodeIfPresent([String: DynamicJSONValue].self, forKey: .input) ?? [:]
      self = .toolUse(CLIToolUse(id: id, name: name, input: input))
    case .toolResult:
      let toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
      let isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
      let content = try container.decode(CLIToolResultContent.self, forKey: .content)
      self = .toolResult(CLIToolResult(toolUseId: toolUseId, isError: isError, content: content))
    case .thinking:
      let thinking = try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""
      let signature = try container.decodeIfPresent(String.self, forKey: .signature)
      self = .thinking(CLIThinking(thinking: thinking, signature: signature))
    case .unknown(_):
      self = .unknown
    }
  }
}

public struct CLIToolUse: Sendable {
  public let id: String
  public let name: String
  public let input: [String: DynamicJSONValue]
}

public struct CLIToolResult: Sendable {
  public let toolUseId: String?
  public let isError: Bool?
  public let content: CLIToolResultContent
}

public enum CLIToolResultContent: Sendable {
  case string(String)
  case items([CLIContentItem])
}

extension CLIToolResultContent: Decodable {
  public init(from decoder: Decoder) throws {
    if let container = try? decoder.singleValueContainer(),
       let stringValue = try? container.decode(String.self) {
      self = .string(stringValue)
      return
    }

    if let items = try? [CLIContentItem](from: decoder) {
      self = .items(items)
      return
    }

    self = .string("")
  }
}

public struct CLIContentItem: Decodable, Sendable {
  public let type: CLIContentItemType?
  public let text: String?
}

public struct CLIThinking: Sendable {
  public let thinking: String
  public let signature: String?
}

public struct CLIUserMessage: Decodable, Sendable {
  public let type: StreamJSONChunkType
  public let sessionId: String?
  public let message: CLIUserMessageContent

  private enum CodingKeys: String, CodingKey {
    case type, sessionId = "session_id", message
  }
}

public struct CLIUserMessageContent: Decodable, Sendable {
  public let role: CLIMessageRole?
  public let content: [CLIContentBlock]
}

public struct CLIResultMessage: Decodable, Sendable {
  public let type: StreamJSONChunkType
  public let subtype: CLIResultSubtype?
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
  public func formattedDescription() -> String {
    self.compactMap { key, value -> String? in
      let formatted = value.stringValue
      guard !formatted.isEmpty else { return nil }
      return "\(key): \(formatted)"
    }.joined(separator: ", ")
  }
}

extension DynamicJSONValue {
  public var stringValue: String {
    switch self {
    case .string(let stringValue): return stringValue
    case .integer(let integerValue): return String(integerValue)
    case .double(let doubleValue): return String(doubleValue)
    case .bool(let boolValue): return String(boolValue)
    case .null: return "null"
    case .array(let arrayValue):
      return "[\(arrayValue.map(\.stringValue).joined(separator: ", "))]"
    case .dictionary(let dictionaryValue):
      return dictionaryValue.formattedDescription()
    }
  }
}

public enum ClaudeCodeClientError: LocalizedError, Equatable {
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
