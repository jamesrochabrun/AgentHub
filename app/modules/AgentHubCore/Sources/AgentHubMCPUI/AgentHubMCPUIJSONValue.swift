//
//  AgentHubMCPUIJSONValue.swift
//  AgentHubMCPUI
//

import Foundation

public enum AgentHubMCPUIJSONValue: Codable, Sendable, Equatable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([AgentHubMCPUIJSONValue])
  case object([String: AgentHubMCPUIJSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([AgentHubMCPUIJSONValue].self) {
      self = .array(array)
    } else if let object = try? container.decode([String: AgentHubMCPUIJSONValue].self) {
      self = .object(object)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  public static func fromJSONObject(_ value: Any) -> AgentHubMCPUIJSONValue {
    switch value {
    case is NSNull:
      return .null
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      return .number(number.doubleValue)
    case let bool as Bool:
      return .bool(bool)
    case let string as String:
      return .string(string)
    case let array as [Any]:
      return .array(array.map { AgentHubMCPUIJSONValue.fromJSONObject($0) })
    case let object as [String: Any]:
      return .object(object.mapValues { AgentHubMCPUIJSONValue.fromJSONObject($0) })
    default:
      return .string(String(describing: value))
    }
  }

  public var jsonObject: Any {
    switch self {
    case .null:
      return NSNull()
    case .bool(let value):
      return value
    case .number(let value):
      return value
    case .string(let value):
      return value
    case .array(let value):
      return value.map(\.jsonObject)
    case .object(let value):
      return value.mapValues(\.jsonObject)
    }
  }

  public var stringValue: String? {
    if case .string(let value) = self {
      return value
    }
    return nil
  }

  public var objectValue: [String: AgentHubMCPUIJSONValue]? {
    if case .object(let value) = self {
      return value
    }
    return nil
  }

  public var arrayValue: [AgentHubMCPUIJSONValue]? {
    if case .array(let value) = self {
      return value
    }
    return nil
  }

  public subscript(key: String) -> AgentHubMCPUIJSONValue? {
    objectValue?[key]
  }
}
