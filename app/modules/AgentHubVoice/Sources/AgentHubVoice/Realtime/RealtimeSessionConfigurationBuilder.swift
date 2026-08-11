import Foundation
import SwiftOpenAI

public enum RealtimeSessionConfigurationBuilder {
  private static let persona = """
    You are AgentHub's concise voice controller. Keep spoken responses brief and natural.
    """

  private static let followUserLanguage = """
    Reply in the language the user is currently speaking. If the language is unclear, use English.
    Do not switch languages because of background audio or your own spoken response.
    """

  private static let sessionDiscipline = """
    Before referring to a session, call list_sessions and use only session IDs returned by tools.
    Never invent or guess a session ID.
    For Claude approval requests, you must call approve_pending_tool without confirmed first,
    read the pending tool and detail back to the user, ask for explicit confirmation, and only
    then call it again with confirmed true. Never claim an action succeeded unless its tool result
    says it succeeded.
    When a session finishes, or the user asks what a session said, found, or produced, call
    read_session_response and answer with a concise spoken summary of its content. Never tell
    the user that results are displayed in the panel, workspace, or screen instead of answering.
    """

  public static let instructions = [persona, followUserLanguage, sessionDiscipline]
    .joined(separator: "\n")

  public static let screenCaptureInstructions = """
    When the user asks about something on their screen, call capture_screen and include the
    returned file path in a send_prompt so the coding session can open the image. When they
    mention a specific or external monitor, call list_displays first and pass the matching
    display_index. Use the region parameter when they point at a specific area.
    """

  public static func instructions(
    for tools: VoiceToolRegistry,
    language: String? = nil
  ) -> String {
    var combined: String
    if let language, let name = languageName(for: language) {
      // A pinned language must REPLACE the follow-the-user's-language
      // directive, not join it: sending both contradictory rules lets
      // background audio or distorted transcription flip the reply language.
      let pinnedLanguage = """
        Always speak and respond in \(name), regardless of the language the \
        user's audio appears to be in. Never switch languages mid-conversation.
        """
      combined = [persona, pinnedLanguage, sessionDiscipline]
        .joined(separator: "\n")
    } else {
      combined = instructions
    }
    let hasScreenCapture = tools.tools.contains { $0.name == "capture_screen" }
    if hasScreenCapture {
      combined += "\n" + screenCaptureInstructions
    }
    return combined
  }

  public static func make(
    settings: VoiceEngineSettings,
    tools: VoiceToolRegistry
  ) -> OpenAIRealtimeSessionConfiguration {
    let eagerness =
      OpenAIRealtimeSessionConfiguration.TurnDetection.DetectionType.Eagerness(
        rawValue: settings.vadEagerness
      ) ?? .medium

    return OpenAIRealtimeSessionConfiguration(
      inputAudioFormat: .pcm16,
      inputAudioTranscription: .init(
        model: settings.dictationModel,
        language: settings.language
      ),
      instructions: instructions(for: tools, language: settings.language),
      modalities: [.audio],
      outputAudioFormat: .pcm16,
      tools: tools.functionTools,
      toolChoice: .auto,
      turnDetection: .init(
        type: .semanticVAD(
          eagerness: eagerness,
          createResponse: true,
          interruptResponse: settings.allowBargeIn
        )
      ),
      voice: settings.voiceName
    )
  }

  static func languageName(for code: String) -> String? {
    Locale(identifier: "en_US").localizedString(forLanguageCode: code)
  }
}
