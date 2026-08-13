import AgentHubVoice
import Foundation

@MainActor
public protocol VoiceToolCataloging: AnyObject {
  /// `assistantMode` builds a standalone-assistant registry: read-only
  /// session visibility plus MCP tools, and none of the tools that push
  /// prompts or content into a session.
  func makeTools(assistantMode: Bool) -> [VoiceTool]
}

public extension VoiceToolCataloging {
  func makeTools() -> [VoiceTool] {
    makeTools(assistantMode: false)
  }
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
  private let mcpToolProvider: (any VoiceMCPToolProviding)?
  private let onBackgroundUpdate: @MainActor @Sendable (String) -> Void
  private let onBackgroundWaitCountChanged:
    (@MainActor @Sendable (Int) -> Void)?
  private var confirmations: [String: ApprovalConfirmation] = [:]
  private lazy var completionWatcher: VoiceSessionCompletionWatcher = .init(
    executor: executor,
    onActiveCountChanged: onBackgroundWaitCountChanged,
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
    mcpToolProvider: (any VoiceMCPToolProviding)? = nil,
    onBackgroundWaitCountChanged: (@MainActor @Sendable (Int) -> Void)? = nil,
    onBackgroundUpdate: @escaping @MainActor @Sendable (String) -> Void
  ) {
    self.executor = executor
    self.screenCapture = screenCapture
    self.isScreenCaptureEnabled = isScreenCaptureEnabled
    self.mcpToolProvider = mcpToolProvider
    self.onBackgroundWaitCountChanged = onBackgroundWaitCountChanged
    self.onBackgroundUpdate = onBackgroundUpdate
  }

  public func makeTools(assistantMode: Bool) -> [VoiceTool] {
    var tools = [
      listSessionsTool(),
      sessionStatusTool(),
      readResponseTool(),
      readHistoryTool(),
      watchSessionTool(),
      stopWatchingTool(),
      focusSessionTool(),
      listWorktreesTool(),
    ]
    if !assistantMode {
      // Session-mutating tools stay out of assistant registries so an
      // assistant conversation can never push prompts, approvals, or new
      // sessions into the user's coding work. Screen capture is excluded too:
      // its file paths are only consumable through send_prompt.
      tools.append(contentsOf: [
        sendPromptTool(),
        launchSessionTool(),
        createWorktreeTasksTool(),
        approvalTool(),
      ])
      if isScreenCaptureEnabled() {
        tools.append(contentsOf: VoiceScreenCaptureTools.make(
          capture: screenCapture,
          isEnabled: isScreenCaptureEnabled
        ))
      }
    }
    if let mcpToolProvider {
      tools.append(contentsOf: mcpToolProvider.currentTools())
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

  private func readHistoryTool() -> VoiceTool {
    VoiceTool(
      name: "read_session_history",
      description: """
        Read a session's recent user/assistant exchanges, oldest first. Use
        this when the user asks what they asked earlier, or what a session has
        been working on beyond its latest answer. For just the latest answer,
        prefer read_session_response.
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
          "turn_limit": [
            "type": "integer",
            "minimum": 1,
            "maximum": 20,
            "description": "How many turns to return. Defaults to 6.",
          ],
        ]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      let arguments = Self.decode(SessionHistoryArguments.self, from: data)
      guard let history = await executor.sessionHistory(
        sessionId: arguments?.sessionId,
        turnLimit: arguments?.turnLimit
          ?? VoiceSessionHistoryLimits.defaultTurnCount
      ) else {
        return Self.encode(
          BasicToolResult(
            status: "not_found",
            message: "That session has no readable conversation yet."
          )
        )
      }
      return Self.encode(history)
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
          "activity_limit": [
            "type": "integer",
            "minimum": 1,
            "maximum": 20,
            "description": """
              How many recent activities to return. Defaults to 3; only raise
              it when the user asks for more detail.
              """,
          ],
        ],
        required: ["session_id"]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      guard let arguments = Self.decode(
        SessionStatusArguments.self,
        from: data
      ) else {
        return Self.invalidArgumentsJSON
      }
      guard let detail = executor.sessionStatus(
        sessionId: arguments.sessionId,
        activityLimit: arguments.activityLimit
          ?? VoiceSessionStatusLimits.defaultActivityCount
      ) else {
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

  private func watchSessionTool() -> VoiceTool {
    VoiceTool(
      name: "watch_session",
      description: """
        Watch a session without sending it anything, and announce when it
        finishes or needs approval. Use when the user asks to observe a
        session, keep an eye on it, or be told when it's done — typically
        while they work in a different session. If the watch times out,
        AgentHub announces the session is still running.
        """,
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
      guard let detail = executor.sessionStatus(
        sessionId: arguments.sessionId
      ) else {
        return Self.encode(
          BasicToolResult(
            status: "not_found",
            message: "No session has that ID."
          )
        )
      }
      completionWatcher.watch(
        sessionId: arguments.sessionId,
        name: detail.name,
        announceTimeout: true
      )
      return Self.encode(
        BasicToolResult(
          status: "watching",
          message: "Watching \(detail.name)."
        )
      )
    }
  }

  private func stopWatchingTool() -> VoiceTool {
    VoiceTool(
      name: "stop_watching",
      description: """
        Stop watching a session the user asked to observe. Omit session_id
        to stop every active watch.
        """,
      parameters: objectSchema(
        properties: [
          "session_id": [
            "type": "string",
            "description": """
              Exact ID returned by list_sessions. Omit to stop all watches.
              """,
          ],
        ]
      )
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      let arguments = Self.decode(OptionalSessionArguments.self, from: data)
      if let sessionId = arguments?.sessionId {
        completionWatcher.cancel(sessionId: sessionId)
      } else {
        completionWatcher.cancelAll()
      }
      return Self.encode(BasicToolResult(status: "stopped", message: nil))
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

  private func listWorktreesTool() -> VoiceTool {
    VoiceTool(
      name: "list_worktrees",
      description: """
        List registered repositories and their worktrees with exact paths and
        session counts. Call this before launch_session or
        create_worktree_tasks so you pass an exact registered path.
        """,
      parameters: objectSchema(properties: [:])
    ) { [weak self] _ in
      guard let self else { return Self.unavailableJSON }
      return Self.encode(executor.listWorktrees())
    }
  }

  private func createWorktreeTasksTool() -> VoiceTool {
    VoiceTool(
      name: "create_worktree_tasks",
      description: """
        Create NEW git worktrees — one per task, a single task is fine — and
        launch an agent session in each with its prompt. Use this whenever the
        user asks to create a worktree, spin up worktree tasks, or run work in
        parallel; never launch_session for those requests. Omit
        repository_path to use the current target session's repository. Read
        the task list back to the user before calling. Branch names are
        adjusted automatically when they collide.
        """,
      parameters: objectSchema(
        properties: [
          "repository_path": [
            "type": "string",
            "description": """
              Only pass this when the user explicitly names a repository or
              path; use the exact registered path from list_worktrees. When
              the user does not name one, OMIT this field entirely — it
              defaults to the repository of the session the user is working
              in. Never guess.
              """,
          ],
          "provider": [
            "type": "string",
            "enum": ["claude", "codex"],
            "description": "Provider for tasks that do not set one. Defaults to claude.",
          ],
          "tasks": .object([
            "type": "array",
            "minItems": 1,
            "items": .object([
              "type": "object",
              "properties": .object([
                "branch": [
                  "type": "string",
                  "description": "Short kebab-case branch name for the task.",
                ],
                "prompt": [
                  "type": "string",
                  "description": "Prompt for the agent launched in this task's worktree.",
                ],
                "provider": [
                  "type": "string",
                  "enum": ["claude", "codex"],
                ],
              ]),
              "required": .array(["branch", "prompt"]),
              "additionalProperties": false,
            ]),
          ]),
        ],
        required: ["tasks"]
      ),
      allowsAutomaticRetry: false
    ) { [weak self] data in
      guard let self else { return Self.unavailableJSON }
      guard let arguments = Self.decode(
        CreateWorktreeTasksArguments.self,
        from: data
      ), !arguments.tasks.isEmpty else {
        return Self.invalidArgumentsJSON
      }
      var specs: [VoiceWorktreeTaskSpec] = []
      for task in arguments.tasks {
        let provider: SessionProviderKind
        if let rawProvider = task.provider ?? arguments.provider {
          guard let kind = Self.providerKind(rawProvider) else {
            return Self.invalidArgumentsJSON
          }
          provider = kind
        } else {
          provider = .claude
        }
        let branch = task.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !prompt.isEmpty else {
          return Self.invalidArgumentsJSON
        }
        specs.append(VoiceWorktreeTaskSpec(
          branch: branch,
          prompt: prompt,
          provider: provider
        ))
      }
      let result = await executor.createWorktreeTasks(
        repositoryPath: arguments.repositoryPath,
        tasks: specs
      )
      for launch in result.launched {
        guard let pendingSessionId = launch.pendingSessionId else { continue }
        completionWatcher.watch(sessionId: pendingSessionId, name: launch.branch)
      }
      return Self.encode(result)
    }
  }

  private func launchSessionTool() -> VoiceTool {
    VoiceTool(
      name: "launch_session",
      description: """
        Start a new agent session in an EXISTING registered repository or
        worktree path, without creating anything on disk. Never use this when
        the user asks to create a worktree — that is create_worktree_tasks.
        """,
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

private struct SessionStatusArguments: Decodable {
  let sessionId: String
  let activityLimit: Int?
}

private struct SessionHistoryArguments: Decodable {
  let sessionId: String?
  let turnLimit: Int?
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

private struct CreateWorktreeTasksArguments: Decodable {
  struct TaskArgument: Decodable {
    let branch: String
    let prompt: String
    let provider: String?
  }

  let repositoryPath: String?
  let provider: String?
  let tasks: [TaskArgument]
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
