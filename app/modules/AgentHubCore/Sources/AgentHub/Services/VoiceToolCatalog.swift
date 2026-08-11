import AgentHubVoice
import Foundation

@MainActor
public protocol VoiceToolCataloging: AnyObject {
  func makeTools() -> [VoiceTool]
}

@MainActor
public final class VoiceToolCatalog: VoiceToolCataloging {
  private struct ApprovalConfirmation {
    let pending: VoicePendingApproval
    let approve: Bool
  }

  private let executor: any VoiceAgentToolExecuting
  private let screenCapture: any VoiceScreenCapturing
  private let isScreenCaptureEnabled: @MainActor @Sendable () -> Bool
  private let onBackgroundUpdate: @MainActor @Sendable (String) -> Void
  private var confirmations: [String: ApprovalConfirmation] = [:]
  private lazy var completionWatcher: VoiceSessionCompletionWatcher = .init(
    executor: executor,
    onUpdate: onBackgroundUpdate
  )

  public init(
    executor: any VoiceAgentToolExecuting,
    screenCapture: any VoiceScreenCapturing = VoiceScreenCaptureService(),
    isScreenCaptureEnabled: @escaping @MainActor @Sendable () -> Bool = {
      (UserDefaults.standard.object(
        forKey: AgentHubDefaults.voiceScreenCaptureEnabled
      ) as? Bool) ?? true
    },
    onBackgroundUpdate: @escaping @MainActor @Sendable (String) -> Void
  ) {
    self.executor = executor
    self.screenCapture = screenCapture
    self.isScreenCaptureEnabled = isScreenCaptureEnabled
    self.onBackgroundUpdate = onBackgroundUpdate
  }

  public func makeTools() -> [VoiceTool] {
    var tools = [
      listSessionsTool(),
      sessionStatusTool(),
      readResponseTool(),
      sendPromptTool(),
      focusSessionTool(),
      launchSessionTool(),
      approvalTool(),
    ]
    if isScreenCaptureEnabled() {
      tools.append(contentsOf: VoiceScreenCaptureTools.make(
        capture: screenCapture,
        isEnabled: isScreenCaptureEnabled
      ))
    }
    return tools
  }

  private func readResponseTool() -> VoiceTool {
    VoiceTool(
      name: "read_session_response",
      description: """
        Read the latest assistant response text from a session so you can
        answer with its actual content. Use this after a session finishes, or
        whenever the user asks what a session said, found, or produced. Never
        tell the user to look at the panel or workspace instead of answering.
        """,
      parameters: objectSchema(
        properties: [
          "session_id": [
            "type": "string",
            "description": """
              Exact ID returned by list_sessions. Omit to use the current
              target session.
              """,
          ],
        ]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      let arguments = Self.decode(OptionalSessionArguments.self, from: data)
      guard let response = await executor.latestResponse(
        sessionId: arguments?.sessionId
      ) else {
        return Self.encode(
          BasicToolResult(
            status: "not_found",
            message: "That session has no readable response yet."
          )
        )
      }
      return Self.encode(response)
    }
  }

  private func listSessionsTool() -> VoiceTool {
    VoiceTool(
      name: "list_sessions",
      description: """
        List AgentHub Claude and Codex sessions. Call this before referencing a
        session so you use an exact session ID.
        """,
      parameters: objectSchema(
        properties: [
          "provider": [
            "type": "string",
            "enum": ["claude", "codex", "all"],
            "description": "Optional provider filter. Defaults to all.",
          ],
        ]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      let arguments = Self.decode(
        OptionalProviderArguments.self,
        from: data
      )
      var summary = executor.listSessions()
      if let provider = arguments?.provider,
         provider != "all",
         let providerKind = Self.providerKind(provider) {
        summary = VoiceSessionsSummary(
          sessions: summary.sessions.filter { $0.provider == providerKind },
          targetSessionId: summary.sessions.contains {
            $0.id == summary.targetSessionId && $0.provider == providerKind
          } ? summary.targetSessionId : nil
        )
      }
      return Self.encode(summary)
    }
  }

  private func sessionStatusTool() -> VoiceTool {
    VoiceTool(
      name: "get_session_status",
      description: "Get live status and recent activity for one exact session ID.",
      parameters: objectSchema(
        properties: [
          "session_id": [
            "type": "string",
            "description": "Exact ID returned by list_sessions.",
          ],
        ],
        required: ["session_id"]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      guard let arguments = Self.decode(SessionArguments.self, from: data) else {
        return Self.invalidArgumentsJSON
      }
      guard let detail = executor.sessionStatus(sessionId: arguments.sessionId) else {
        return Self.encode(
          BasicToolResult(
            status: "not_found",
            message: "No session has that ID."
          )
        )
      }
      return Self.encode(detail)
    }
  }

  private func sendPromptTool() -> VoiceTool {
    VoiceTool(
      name: "send_prompt",
      description: """
        Send a prompt to an existing AgentHub session. Returns immediately; when
        requested, AgentHub will announce completion as a later session update.
        """,
      parameters: objectSchema(
        properties: [
          "session_id": [
            "type": "string",
            "description": "Exact ID returned by list_sessions.",
          ],
          "prompt": [
            "type": "string",
            "description": "Prompt to send to the session.",
          ],
          "wait_for_completion": [
            "type": "boolean",
            "description": "Announce when the session finishes. Defaults to true.",
          ],
        ],
        required: ["session_id", "prompt"]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      guard let arguments = Self.decode(SendPromptArguments.self, from: data),
            !arguments.prompt.trimmingCharacters(
              in: .whitespacesAndNewlines
            ).isEmpty else {
        return Self.invalidArgumentsJSON
      }
      let name = executor.sessionStatus(sessionId: arguments.sessionId)?.name
        ?? "Session \(arguments.sessionId.prefix(8))"
      let result = executor.sendPrompt(
        sessionId: arguments.sessionId,
        prompt: arguments.prompt
      )
      if result.status == "accepted",
         arguments.waitForCompletion ?? true {
        completionWatcher.watch(sessionId: arguments.sessionId, name: name)
      }
      return Self.encode(result)
    }
  }

  private func focusSessionTool() -> VoiceTool {
    VoiceTool(
      name: "focus_session",
      description: "Focus a session in AgentHub and direct keyboard input to it.",
      parameters: objectSchema(
        properties: [
          "session_id": [
            "type": "string",
            "description": "Exact ID returned by list_sessions.",
          ],
        ],
        required: ["session_id"]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      guard let arguments = Self.decode(SessionArguments.self, from: data) else {
        return Self.invalidArgumentsJSON
      }
      let focused = executor.focusSession(sessionId: arguments.sessionId)
      return Self.encode(
        BasicToolResult(
          status: focused ? "focused" : "not_found",
          message: focused ? nil : "No session has that ID."
        )
      )
    }
  }

  private func launchSessionTool() -> VoiceTool {
    VoiceTool(
      name: "launch_session",
      description: "Launch a new Claude or Codex session in a registered worktree.",
      parameters: objectSchema(
        properties: [
          "worktree_path": [
            "type": "string",
            "description": "Exact registered repository or worktree path.",
          ],
          "provider": [
            "type": "string",
            "enum": ["claude", "codex"],
          ],
          "prompt": [
            "type": "string",
            "description": "Optional initial prompt.",
          ],
        ],
        required: ["worktree_path", "provider"]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      guard let arguments = Self.decode(LaunchArguments.self, from: data),
            let provider = Self.providerKind(arguments.provider) else {
        return Self.invalidArgumentsJSON
      }
      let result = executor.launchSession(
        worktreePath: arguments.worktreePath,
        provider: provider,
        prompt: arguments.prompt
      )
      if result.status == "accepted",
         let pendingSessionId = result.pendingSessionId {
        completionWatcher.watch(
          sessionId: pendingSessionId,
          name: "\(provider.rawValue.capitalized) session"
        )
      }
      return Self.encode(result)
    }
  }

  private func approvalTool() -> VoiceTool {
    VoiceTool(
      name: "approve_pending_tool",
      description: """
        Approve or deny a pending Claude tool. First call without confirmed,
        read the returned tool and detail aloud, ask the user, then call again
        with confirmed true. Codex approvals are not supported.
        """,
      parameters: objectSchema(
        properties: [
          "session_id": [
            "type": "string",
            "description": "Exact Claude session ID returned by list_sessions.",
          ],
          "decision": [
            "type": "string",
            "enum": ["approve", "deny"],
          ],
          "confirmed": [
            "type": "boolean",
            "description": "True only after explicit spoken user confirmation.",
          ],
        ],
        required: ["session_id", "decision"]
      ),
      allowsAutomaticRetry: false
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      guard let arguments = Self.decode(ApprovalArguments.self, from: data),
            ["approve", "deny"].contains(arguments.decision) else {
        return Self.invalidArgumentsJSON
      }
      return handleApproval(arguments)
    }
  }

  private func handleApproval(_ arguments: ApprovalArguments) -> String {
    if executor.sessionStatus(sessionId: arguments.sessionId)?.provider == .codex {
      return Self.encode(
        BasicToolResult(
          status: "rejected",
          message: "Voice approvals are supported for Claude sessions only."
        )
      )
    }
    guard let pending = executor.pendingApproval(
      sessionId: arguments.sessionId
    ) else {
      confirmations.removeValue(forKey: arguments.sessionId)
      return Self.encode(
        BasicToolResult(
          status: "stale",
          message: "There is no longer a pending Claude approval."
        )
      )
    }
    let approve = arguments.decision == "approve"

    guard arguments.confirmed == true else {
      confirmations[arguments.sessionId] = ApprovalConfirmation(
        pending: pending,
        approve: approve
      )
      return Self.encode(
        ApprovalConfirmationRequired(
          status: "confirmation_required",
          pendingTool: pending,
          instruction: """
            Read the pending tool and detail back to the user, ask for explicit
            confirmation, then call again with confirmed true.
            """
        )
      )
    }

    guard let confirmation = confirmations.removeValue(
      forKey: arguments.sessionId
    ),
      confirmation.pending.toolUseId == pending.toolUseId,
      confirmation.pending.toolName == pending.toolName,
      confirmation.approve == approve else {
      return Self.encode(
        BasicToolResult(
          status: "stale",
          message: "The pending approval changed or was not confirmed."
        )
      )
    }
    return Self.encode(
      executor.respondToApproval(
        sessionId: arguments.sessionId,
        approve: approve
      )
    )
  }

  private func objectSchema(
    properties: [String: VoiceJSONValue],
    required: [String] = []
  ) -> [String: VoiceJSONValue] {
    var schema: [String: VoiceJSONValue] = [
      "type": "object",
      "properties": .object(properties),
      "additionalProperties": false,
    ]
    if !required.isEmpty {
      schema["required"] = .array(required.map(VoiceJSONValue.string))
    }
    return schema
  }

  private static func providerKind(_ rawValue: String) -> SessionProviderKind? {
    switch rawValue.lowercased() {
    case "claude":
      .claude
    case "codex":
      .codex
    default:
      nil
    }
  }

  private static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data
  ) -> T? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(type, from: data)
  }

  private static func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else {
      return unavailableJSON
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static let unavailableJSON =
    #"{"status":"error","message":"Voice tools are unavailable."}"#
  private static let invalidArgumentsJSON =
    #"{"status":"error","message":"Invalid tool arguments."}"#
}

private struct OptionalProviderArguments: Decodable {
  let provider: String?
}

private struct SessionArguments: Decodable {
  let sessionId: String
}

private struct OptionalSessionArguments: Decodable {
  let sessionId: String?
}

private struct SendPromptArguments: Decodable {
  let sessionId: String
  let prompt: String
  let waitForCompletion: Bool?
}

private struct LaunchArguments: Decodable {
  let worktreePath: String
  let provider: String
  let prompt: String?
}

private struct ApprovalArguments: Decodable {
  let sessionId: String
  let decision: String
  let confirmed: Bool?
}

private struct BasicToolResult: Encodable {
  let status: String
  let message: String?
}

private struct ApprovalConfirmationRequired: Encodable {
  let status: String
  let pendingTool: VoicePendingApproval
  let instruction: String
}
