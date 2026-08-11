import Foundation
import Testing
@testable import AgentHubVoice

struct RealtimeSessionConfigurationBuilderTests {
  @Test
  func buildsAudioSemanticVADAndFunctionTools() throws {
    let tool = VoiceTool(
      name: "list_sessions",
      description: "Lists sessions",
      parameters: ["type": "object"]
    ) { _ in
      "{}"
    }
    let configuration = RealtimeSessionConfigurationBuilder.make(
      settings: VoiceEngineSettings(
        model: "gpt-realtime",
        voiceName: "marin",
        vadEagerness: "high",
        dictationModel: "whisper-1"
      ),
      tools: VoiceToolRegistry(tools: [tool])
    )

    let data = try JSONEncoder().encode(configuration)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let audio = try #require(object["audio"] as? [String: Any])
    let input = try #require(audio["input"] as? [String: Any])
    let output = try #require(audio["output"] as? [String: Any])
    let turnDetection = try #require(input["turn_detection"] as? [String: Any])
    let tools = try #require(object["tools"] as? [[String: Any]])

    #expect(object["output_modalities"] as? [String] == ["audio"])
    #expect(output["voice"] as? String == "marin")
    #expect(turnDetection["type"] as? String == "semantic_vad")
    #expect(turnDetection["eagerness"] as? String == "high")
    #expect(tools.first?["name"] as? String == "list_sessions")
    #expect(
      RealtimeSessionConfigurationBuilder.instructions.contains(
        "If the language is unclear, use English."
      )
    )
  }

  @Test
  func instructionsEnforceSessionAndApprovalDiscipline() {
    let instructions = RealtimeSessionConfigurationBuilder.instructions

    #expect(instructions.contains("call list_sessions"))
    #expect(instructions.contains("Never invent"))
    #expect(instructions.contains("explicit confirmation"))
  }

  @Test
  func pinnedLanguageShapesInstructionsTranscriptionAndBargeIn() throws {
    let configuration = RealtimeSessionConfigurationBuilder.make(
      settings: VoiceEngineSettings(
        language: "es",
        allowBargeIn: false
      ),
      tools: VoiceToolRegistry(tools: [])
    )

    let data = try JSONEncoder().encode(configuration)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let audio = try #require(object["audio"] as? [String: Any])
    let input = try #require(audio["input"] as? [String: Any])
    let transcription = try #require(input["transcription"] as? [String: Any])
    let turnDetection = try #require(input["turn_detection"] as? [String: Any])
    let instructions = try #require(object["instructions"] as? String)

    #expect(transcription["language"] as? String == "es")
    #expect(turnDetection["interrupt_response"] as? Bool == false)
    #expect(instructions.contains("Always speak and respond in Spanish"))
    #expect(instructions.contains("Never switch languages"))
    // The pin must REPLACE the follow-the-user's-language directive — sending
    // both contradictory rules lets background audio flip the reply language.
    #expect(
      !instructions.contains("Reply in the language the user is currently speaking")
    )
    #expect(!instructions.contains("If the language is unclear, use English."))
    // Pinning must not drop the session/approval discipline rules.
    #expect(instructions.contains("call list_sessions"))
    #expect(instructions.contains("explicit confirmation"))
  }

  @Test
  func automaticLanguageKeepsFollowTheUserBehavior() {
    let instructions = RealtimeSessionConfigurationBuilder.instructions(
      for: VoiceToolRegistry(tools: []),
      language: nil
    )

    #expect(!instructions.contains("Never switch languages mid-conversation."))
    #expect(instructions.contains("Reply in the language the user is currently speaking."))
  }

  @Test
  func screenCaptureInstructionsOnlyAppearWithTheCaptureTool() {
    let captureTool = VoiceTool(
      name: "capture_screen",
      description: "Captures",
      parameters: ["type": "object"]
    ) { _ in
      "{}"
    }
    let otherTool = VoiceTool(
      name: "list_sessions",
      description: "Lists sessions",
      parameters: ["type": "object"]
    ) { _ in
      "{}"
    }

    let withCapture = RealtimeSessionConfigurationBuilder.instructions(
      for: VoiceToolRegistry(tools: [otherTool, captureTool])
    )
    #expect(withCapture.contains("call capture_screen"))
    #expect(withCapture.contains("list_displays"))

    let withoutCapture = RealtimeSessionConfigurationBuilder.instructions(
      for: VoiceToolRegistry(tools: [otherTool])
    )
    #expect(!withoutCapture.contains("capture_screen"))
  }
}
