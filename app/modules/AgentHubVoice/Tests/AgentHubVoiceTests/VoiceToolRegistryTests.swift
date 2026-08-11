import Foundation
import SwiftOpenAI
import Testing
@testable import AgentHubVoice

@MainActor
struct VoiceToolRegistryTests {
  @Test
  func dispatchesKnownTool() async {
    let registry = VoiceToolRegistry(
      tools: [
        VoiceTool(
          name: "echo",
          description: "Echo input",
          parameters: ["type": "object"]
        ) { data in
          String(decoding: data, as: UTF8.self)
        }
      ]
    )

    let output = await registry.execute(name: "echo", arguments: #"{"value":"hi"}"#)

    #expect(output == #"{"value":"hi"}"#)
    #expect(registry.functionTools.count == 1)
  }

  @Test
  func reportsUnknownToolAsJSON() async throws {
    let registry = VoiceToolRegistry(tools: [])

    let output = await registry.execute(name: "missing", arguments: "{}")
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String]
    )

    #expect(object["code"] == "unknown_tool")
  }

  @Test
  func rejectsMalformedArguments() async throws {
    let registry = VoiceToolRegistry(
      tools: [
        VoiceTool(
          name: "echo",
          description: "Echo input",
          parameters: ["type": "object"]
        ) { _ in
          "unexpected"
        }
      ]
    )

    let output = await registry.execute(name: "echo", arguments: "not json")
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String]
    )

    #expect(object["code"] == "invalid_arguments")
  }
}
