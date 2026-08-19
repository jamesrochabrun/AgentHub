import Foundation
import SwiftOpenAI

public enum RealtimeSessionConfigurationBuilder {
  private static let persona = """
    You are AgentHub's concise voice controller. Keep spoken responses brief and natural.
    """

  /// Persona for registries without session-mutating tools (no `send_prompt`):
  /// a standalone assistant that answers directly instead of delegating.
  private static let assistantPersona = """
    You are a concise, hands-free voice assistant. Keep spoken responses brief and natural.
    Answer the user directly using your tools. In this mode you cannot send prompts, files,
    or any content into a coding session — never claim you did, and never suggest routing an
    answer through a session; just answer yourself.
    """

  /// Read-only session guidance for assistant registries that still expose
  /// session visibility tools.
  private static let assistantSessionReadDiscipline = """
    You have read-only visibility into the user's coding sessions. Before referring to a
    session, call list_sessions and use only session IDs returned by tools; never invent or
    guess a session ID. When the user asks what a session said, found, or produced, call
    read_session_response and answer with a concise spoken summary of its content.
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

  public static let worktreeTaskInstructions = """
    When the user asks to create a worktree, create worktree tasks, or run tasks in parallel —
    even a single one — call create_worktree_tasks. launch_session never creates a worktree;
    only use it when the user asks to start a session in an existing repository or worktree.
    When calling create_worktree_tasks, omit repository_path unless the user explicitly names
    a repository or path — omitted, it defaults to the repository of the session the user is
    working in, which is what they usually mean. Never guess a repository or reuse one from an
    earlier answer. After the tool returns, tell the user which repository was used.
    """

  public static let sessionHistoryInstructions = """
    read_session_response only returns a session's latest answer. When the user asks about
    earlier prompts, or what a session has been working on over time, call
    read_session_history instead.
    """

  public static func instructions(
    for tools: VoiceToolRegistry,
    language: String? = nil,
    sessionContext: String? = nil
  ) -> String {
    // `send_prompt` marks a session-controller registry; without it the
    // conversation is a standalone assistant and must not be instructed to
    // route anything through sessions.
    let isSessionController = tools.tools.contains { $0.name == "send_prompt" }
    let hasSessionVisibility = tools.tools.contains { $0.name == "list_sessions" }

    var blocks: [String] = [isSessionController ? persona : assistantPersona]
    if let language, let name = languageName(for: language) {
      // A pinned language must REPLACE the follow-the-user's-language
      // directive, not join it: sending both contradictory rules lets
      // background audio or distorted transcription flip the reply language.
      blocks.append("""
        Always speak and respond in \(name), regardless of the language the \
        user's audio appears to be in. Never switch languages mid-conversation.
        """)
    } else {
      blocks.append(followUserLanguage)
    }
    if isSessionController {
      blocks.append(sessionDiscipline)
    } else if hasSessionVisibility {
      blocks.append(assistantSessionReadDiscipline)
    }
    var combined = blocks.joined(separator: "\n")
    let hasScreenCapture = tools.tools.contains { $0.name == "capture_screen" }
    if hasScreenCapture {
      combined += "\n" + screenCaptureInstructions
    }
    let hasWorktreeTasks = tools.tools.contains { $0.name == "create_worktree_tasks" }
    if hasWorktreeTasks {
      combined += "\n" + worktreeTaskInstructions
    }
    let hasSessionHistory = tools.tools.contains { $0.name == "read_session_history" }
    if hasSessionHistory {
      combined += "\n" + sessionHistoryInstructions
    }
    let mcpServers = mcpServerNames(in: tools)
    if !mcpServers.isEmpty {
      combined += """
        \nYou also have external tools from the user's MCP servers: \
        \(mcpServers.joined(separator: ", ")). Their tool names are prefixed \
        with the server name. When the user asks what you can do or which \
        tools you have, name these servers and briefly say what their tools \
        offer.
        """
    }
    if let sessionContext = sessionContext?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ), !sessionContext.isEmpty {
      combined += """
        \nSession snapshot from when this conversation connected — it may be \
        stale and has no IDs. Use it for awareness only; always call \
        list_sessions before acting on a session.
        \(sessionContext)
        """
    }
    return combined
  }

  public static func make(
    settings: VoiceEngineSettings,
    tools: VoiceToolRegistry,
    sessionContext: String? = nil
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
      instructions: instructions(
        for: tools,
        language: settings.language,
        sessionContext: sessionContext
      ),
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

  /// MCP-bridged tools are namespaced `{server}__{tool}`; every other tool
  /// name in the catalog is a plain snake_case verb, so a `__` separator
  /// reliably marks an MCP tool.
  static func mcpServerNames(in tools: VoiceToolRegistry) -> [String] {
    Set(
      tools.tools.compactMap { tool -> String? in
        guard let range = tool.name.range(of: "__"),
              range.lowerBound != tool.name.startIndex else { return nil }
        return String(tool.name[..<range.lowerBound])
      }
    )
    .sorted()
  }
}
