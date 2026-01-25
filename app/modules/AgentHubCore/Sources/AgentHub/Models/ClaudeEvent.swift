//
//  ClaudeEvent.swift
//  AgentHub
//
//  Event types for Claude Code headless mode JSONL streaming.
//  Based on the stream-json output format.
//

import Foundation

// MARK: - ClaudeEvent

/// Top-level event type streamed from Claude Code headless mode.
/// Each line of JSONL output maps to one of these event types.
public enum ClaudeEvent: Sendable, Equatable {
  case system(ClaudeSystemEvent)
  case assistant(ClaudeAssistantEvent)
  case user(ClaudeUserEvent)
  case toolResult(ClaudeToolResultEvent)
  case controlRequest(ClaudeControlRequestEvent)
  case result(ClaudeResultEvent)
  case unknown
}

// MARK: - ClaudeEvent Codable

extension ClaudeEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
  }

  private enum EventType: String, Codable {
    case system
    case assistant
    case user
    case toolResult = "tool_result"
    case controlRequest = "control_request"
    case result
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    guard let type = try? container.decode(EventType.self, forKey: .type) else {
      self = .unknown
      return
    }

    let singleValueContainer = try decoder.singleValueContainer()

    switch type {
    case .system:
      let event = try singleValueContainer.decode(ClaudeSystemEvent.self)
      self = .system(event)
    case .assistant:
      let event = try singleValueContainer.decode(ClaudeAssistantEvent.self)
      self = .assistant(event)
    case .user:
      let event = try singleValueContainer.decode(ClaudeUserEvent.self)
      self = .user(event)
    case .toolResult:
      let event = try singleValueContainer.decode(ClaudeToolResultEvent.self)
      self = .toolResult(event)
    case .controlRequest:
      let event = try singleValueContainer.decode(ClaudeControlRequestEvent.self)
      self = .controlRequest(event)
    case .result:
      let event = try singleValueContainer.decode(ClaudeResultEvent.self)
      self = .result(event)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var singleValueContainer = encoder.singleValueContainer()

    switch self {
    case .system(let event):
      try singleValueContainer.encode(event)
    case .assistant(let event):
      try singleValueContainer.encode(event)
    case .user(let event):
      try singleValueContainer.encode(event)
    case .toolResult(let event):
      try singleValueContainer.encode(event)
    case .controlRequest(let event):
      try singleValueContainer.encode(event)
    case .result(let event):
      try singleValueContainer.encode(event)
    case .unknown:
      try singleValueContainer.encodeNil()
    }
  }
}

// MARK: - ClaudeSystemEvent

/// System event emitted at session start with metadata.
public struct ClaudeSystemEvent: Codable, Sendable, Equatable {
  public let type: String
  public let subtype: String?
  public let sessionId: String?
  public let model: String?
  public let tools: [String]?
  public let cwd: String?

  private enum CodingKeys: String, CodingKey {
    case type
    case subtype
    case sessionId = "session_id"
    case model
    case tools
    case cwd
  }

  public init(
    type: String = "system",
    subtype: String? = nil,
    sessionId: String? = nil,
    model: String? = nil,
    tools: [String]? = nil,
    cwd: String? = nil
  ) {
    self.type = type
    self.subtype = subtype
    self.sessionId = sessionId
    self.model = model
    self.tools = tools
    self.cwd = cwd
  }
}

// MARK: - ClaudeAssistantEvent

/// Assistant event containing a message with content blocks.
public struct ClaudeAssistantEvent: Codable, Sendable, Equatable {
  public let type: String
  public let message: ClaudeMessage?
  public let sessionId: String?
  public let error: String?

  private enum CodingKeys: String, CodingKey {
    case type
    case message
    case sessionId = "session_id"
    case error
  }

  public init(
    type: String = "assistant",
    message: ClaudeMessage? = nil,
    sessionId: String? = nil,
    error: String? = nil
  ) {
    self.type = type
    self.message = message
    self.sessionId = sessionId
    self.error = error
  }
}

// MARK: - ClaudeMessage

/// A message object within an assistant event.
public struct ClaudeMessage: Codable, Sendable, Equatable {
  public let id: String?
  public let role: String?
  public let model: String?
  public let content: [ClaudeContentBlock]?
  public let stopReason: String?
  public let usage: ClaudeUsage?

  private enum CodingKeys: String, CodingKey {
    case id
    case role
    case model
    case content
    case stopReason = "stop_reason"
    case usage
  }

  public init(
    id: String? = nil,
    role: String? = nil,
    model: String? = nil,
    content: [ClaudeContentBlock]? = nil,
    stopReason: String? = nil,
    usage: ClaudeUsage? = nil
  ) {
    self.id = id
    self.role = role
    self.model = model
    self.content = content
    self.stopReason = stopReason
    self.usage = usage
  }

  /// Extracts all text content from the message
  public var textContent: String? {
    guard let content = content else { return nil }
    let texts = content.compactMap { block -> String? in
      if case .text(let text) = block {
        return text
      }
      return nil
    }
    return texts.isEmpty ? nil : texts.joined(separator: "\n")
  }

  /// Extracts all tool use blocks from the message
  public var toolUseBlocks: [ClaudeToolUseBlock] {
    guard let content = content else { return [] }
    return content.compactMap { block -> ClaudeToolUseBlock? in
      if case .toolUse(let toolUse) = block {
        return toolUse
      }
      return nil
    }
  }
}

// MARK: - ClaudeContentBlock

/// A content block within a message (text or tool_use).
public enum ClaudeContentBlock: Sendable, Equatable {
  case text(String)
  case toolUse(ClaudeToolUseBlock)
  case other
}

extension ClaudeContentBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case id
    case name
    case input
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "text":
      let text = try container.decode(String.self, forKey: .text)
      self = .text(text)
    case "tool_use":
      let id = try container.decode(String.self, forKey: .id)
      let name = try container.decode(String.self, forKey: .name)
      let input = try container.decode(JSONValue.self, forKey: .input)
      self = .toolUse(ClaudeToolUseBlock(id: id, name: name, input: input))
    default:
      self = .other
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .toolUse(let toolUse):
      try container.encode("tool_use", forKey: .type)
      try container.encode(toolUse.id, forKey: .id)
      try container.encode(toolUse.name, forKey: .name)
      try container.encode(toolUse.input, forKey: .input)
    case .other:
      try container.encode("other", forKey: .type)
    }
  }
}

// MARK: - ClaudeToolUseBlock

/// A tool use block within message content.
public struct ClaudeToolUseBlock: Sendable, Equatable {
  public let id: String
  public let name: String
  public let input: JSONValue

  public init(id: String, name: String, input: JSONValue) {
    self.id = id
    self.name = name
    self.input = input
  }
}

// MARK: - ClaudeUserEvent

/// User event containing tool results from Claude Code CLI.
public struct ClaudeUserEvent: Codable, Sendable, Equatable {
  public let type: String
  public let message: ClaudeUserMessage?

  private enum CodingKeys: String, CodingKey {
    case type
    case message
  }

  public init(
    type: String = "user",
    message: ClaudeUserMessage? = nil
  ) {
    self.type = type
    self.message = message
  }
}

// MARK: - ClaudeUserMessage

/// A user message object, typically containing tool results.
public struct ClaudeUserMessage: Codable, Sendable, Equatable {
  public let role: String?
  public let content: [ClaudeUserContentBlock]?

  public init(role: String? = nil, content: [ClaudeUserContentBlock]? = nil) {
    self.role = role
    self.content = content
  }
}

// MARK: - ClaudeUserContentBlock

/// Content block in a user message (typically tool_result).
public enum ClaudeUserContentBlock: Sendable, Equatable {
  case toolResult(ClaudeToolResultBlock)
  case text(String)
  case other
}

extension ClaudeUserContentBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case toolUseId = "tool_use_id"
    case content
    case isError = "is_error"
    case text
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "tool_result":
      let toolUseId = try container.decode(String.self, forKey: .toolUseId)
      let content = try container.decodeIfPresent(String.self, forKey: .content)
      let isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
      self = .toolResult(ClaudeToolResultBlock(toolUseId: toolUseId, content: content, isError: isError))
    case "text":
      let text = try container.decode(String.self, forKey: .text)
      self = .text(text)
    default:
      self = .other
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .toolResult(let result):
      try container.encode("tool_result", forKey: .type)
      try container.encode(result.toolUseId, forKey: .toolUseId)
      try container.encodeIfPresent(result.content, forKey: .content)
      try container.encodeIfPresent(result.isError, forKey: .isError)
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .other:
      try container.encode("other", forKey: .type)
    }
  }
}

// MARK: - ClaudeToolResultBlock

/// A tool result block within user content.
public struct ClaudeToolResultBlock: Sendable, Equatable {
  public let toolUseId: String
  public let content: String?
  public let isError: Bool?

  public init(toolUseId: String, content: String? = nil, isError: Bool? = nil) {
    self.toolUseId = toolUseId
    self.content = content
    self.isError = isError
  }
}

// MARK: - ClaudeToolResultEvent

/// Standalone tool result event (alternative format).
public struct ClaudeToolResultEvent: Codable, Sendable, Equatable {
  public let type: String
  public let toolUseId: String?
  public let content: String?
  public let isError: Bool?

  private enum CodingKeys: String, CodingKey {
    case type
    case toolUseId = "tool_use_id"
    case content
    case isError = "is_error"
  }

  public init(
    type: String = "tool_result",
    toolUseId: String? = nil,
    content: String? = nil,
    isError: Bool? = nil
  ) {
    self.type = type
    self.toolUseId = toolUseId
    self.content = content
    self.isError = isError
  }
}

// MARK: - ClaudeControlRequestEvent

/// Control request event for permission prompts (tool approval).
public struct ClaudeControlRequestEvent: Codable, Sendable, Equatable {
  public let type: String
  public let requestId: String
  public let request: ClaudeControlRequest

  private enum CodingKeys: String, CodingKey {
    case type
    case requestId = "request_id"
    case request
  }

  public init(
    type: String = "control_request",
    requestId: String,
    request: ClaudeControlRequest
  ) {
    self.type = type
    self.requestId = requestId
    self.request = request
  }
}

// MARK: - ClaudeControlRequest

/// The request payload within a control_request event.
public enum ClaudeControlRequest: Sendable, Equatable {
  case canUseTool(toolName: String, input: JSONValue, toolUseId: String?)
  case hookCallback(callbackId: String, input: JSONValue)
  case unknown
}

extension ClaudeControlRequest: Codable {
  private enum CodingKeys: String, CodingKey {
    case subtype
    case toolName = "tool_name"
    case input
    case toolUseId = "tool_use_id"
    case callbackId = "callback_id"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let subtype = try container.decode(String.self, forKey: .subtype)

    switch subtype {
    case "can_use_tool":
      let toolName = try container.decode(String.self, forKey: .toolName)
      let input = try container.decode(JSONValue.self, forKey: .input)
      let toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
      self = .canUseTool(toolName: toolName, input: input, toolUseId: toolUseId)
    case "hook_callback":
      let callbackId = try container.decode(String.self, forKey: .callbackId)
      let input = try container.decode(JSONValue.self, forKey: .input)
      self = .hookCallback(callbackId: callbackId, input: input)
    default:
      self = .unknown
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .canUseTool(let toolName, let input, let toolUseId):
      try container.encode("can_use_tool", forKey: .subtype)
      try container.encode(toolName, forKey: .toolName)
      try container.encode(input, forKey: .input)
      try container.encodeIfPresent(toolUseId, forKey: .toolUseId)
    case .hookCallback(let callbackId, let input):
      try container.encode("hook_callback", forKey: .subtype)
      try container.encode(callbackId, forKey: .callbackId)
      try container.encode(input, forKey: .input)
    case .unknown:
      try container.encode("unknown", forKey: .subtype)
    }
  }
}

// MARK: - ClaudeResultEvent

/// Result event emitted at the end of a session.
public struct ClaudeResultEvent: Codable, Sendable, Equatable {
  public let type: String
  public let result: String?
  public let output: String?
  public let isError: Bool?
  public let error: String?
  public let sessionId: String?
  public let usage: ClaudeUsage?

  private enum CodingKeys: String, CodingKey {
    case type
    case result
    case output
    case isError = "is_error"
    case error
    case sessionId = "session_id"
    case usage
  }

  public init(
    type: String = "result",
    result: String? = nil,
    output: String? = nil,
    isError: Bool? = nil,
    error: String? = nil,
    sessionId: String? = nil,
    usage: ClaudeUsage? = nil
  ) {
    self.type = type
    self.result = result
    self.output = output
    self.isError = isError
    self.error = error
    self.sessionId = sessionId
    self.usage = usage
  }
}

// MARK: - ClaudeUsage

/// Token usage information.
public struct ClaudeUsage: Codable, Sendable, Equatable {
  public let inputTokens: Int?
  public let outputTokens: Int?

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
  }

  public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

// MARK: - JSONValue

/// Type-erased Codable wrapper for JSON values.
/// Used for tool inputs which can be arbitrary JSON.
public struct JSONValue: Codable, Sendable, Equatable {
  public let value: Any

  public init(_ value: Any) {
    self.value = value
  }

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
    } else if let array = try? container.decode([JSONValue].self) {
      self.value = array.map { $0.value }
    } else if let dictionary = try? container.decode([String: JSONValue].self) {
      self.value = dictionary.mapValues { $0.value }
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "JSONValue cannot decode value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch value {
    case is NSNull:
      try container.encodeNil()
    case let bool as Bool:
      try container.encode(bool)
    case let int as Int:
      try container.encode(int)
    case let double as Double:
      try container.encode(double)
    case let string as String:
      try container.encode(string)
    case let array as [Any]:
      try container.encode(array.map { JSONValue($0) })
    case let dictionary as [String: Any]:
      try container.encode(dictionary.mapValues { JSONValue($0) })
    default:
      throw EncodingError.invalidValue(
        value,
        EncodingError.Context(codingPath: container.codingPath, debugDescription: "JSONValue cannot encode value")
      )
    }
  }

  public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
    // Simple equality check - compare JSON representations
    let encoder = JSONEncoder()
    guard let lhsData = try? encoder.encode(lhs),
          let rhsData = try? encoder.encode(rhs) else {
      return false
    }
    return lhsData == rhsData
  }

  /// Convenience accessor for dictionary values
  public subscript(key: String) -> Any? {
    (value as? [String: Any])?[key]
  }

  /// Returns the value as a dictionary if possible
  public var dictionary: [String: Any]? {
    value as? [String: Any]
  }

  /// Returns the value as a string if possible
  public var string: String? {
    value as? String
  }
}
