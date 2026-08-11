import Foundation
import SwiftOpenAI

public typealias VoiceJSONValue = OpenAIJSONValue

public typealias VoiceToolHandler =
  @MainActor @Sendable (_ arguments: Data) async -> String

public struct VoiceTool: Sendable {
  public let name: String
  public let description: String
  public let parameters: [String: OpenAIJSONValue]
  public let allowsAutomaticRetry: Bool
  private let handler: VoiceToolHandler

  public init(
    name: String,
    description: String,
    parameters: [String: OpenAIJSONValue],
    allowsAutomaticRetry: Bool = true,
    handler: @escaping VoiceToolHandler
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.allowsAutomaticRetry = allowsAutomaticRetry
    self.handler = handler
  }

  @MainActor
  fileprivate func execute(arguments: Data) async -> String {
    await handler(arguments)
  }
}

public struct VoiceToolRegistry: Sendable {
  public let tools: [VoiceTool]

  public init(tools: [VoiceTool]) {
    self.tools = tools
  }

  public var functionTools: [OpenAIRealtimeSessionConfiguration.RealtimeTool] {
    tools.map { tool in
      .function(
        .init(
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters
        )
      )
    }
  }

  @MainActor
  public func execute(name: String, arguments: String) async -> String {
    guard let tool = tools.first(where: { $0.name == name }) else {
      return Self.errorJSON(code: "unknown_tool", message: "Unknown tool: \(name)")
    }
    guard let data = arguments.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          object is [String: Any] else {
      return Self.errorJSON(
        code: "invalid_arguments",
        message: "Tool arguments must be a JSON object."
      )
    }
    return await tool.execute(arguments: data)
  }

  private static func errorJSON(code: String, message: String) -> String {
    let object: [String: Any] = [
      "status": "error",
      "code": code,
      "message": message,
    ]
    guard let data = try? JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    ) else {
      return #"{"status":"error"}"#
    }
    return String(decoding: data, as: UTF8.self)
  }
}
