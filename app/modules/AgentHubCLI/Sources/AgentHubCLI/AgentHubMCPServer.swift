import AgentHubCLIKit
import Foundation

struct AgentHubMCPServer {
  private let service = WorktreeManagementService()
  private let queue = WorktreeLaunchRequestQueue()

  func run() async throws {
    while let line = readLine(strippingNewline: true) {
      guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      await handleLine(line)
    }
  }

  private func handleLine(_ line: String) async {
    do {
      guard let data = line.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String else {
        return
      }

      let id = object["id"]
      switch method {
      case "initialize":
        guard let id else { return }
        let protocolVersion = ((object["params"] as? [String: Any])?["protocolVersion"] as? String)
          ?? "2024-11-05"
        writeResponse(id: id, result: [
          "protocolVersion": protocolVersion,
          "capabilities": [
            "tools": [:]
          ],
          "serverInfo": [
            "name": "agenthub",
            "version": "1.0.0"
          ]
        ])

      case "tools/list":
        guard let id else { return }
        writeResponse(id: id, result: [
          "tools": [
            createWorktreeSessionToolSchema(),
            createWorktreeSessionsToolSchema()
          ]
        ])

      case "tools/call":
        guard let id else { return }
        let result = try await handleToolCall(params: object["params"] as? [String: Any])
        writeResponse(id: id, result: result)

      default:
        guard let id else { return }
        writeError(id: id, code: -32601, message: "Method not found: \(method)")
      }
    } catch {
      let id = requestId(from: line)
      writeError(id: id, code: -32000, message: error.localizedDescription)
    }
  }

  private func handleToolCall(params: [String: Any]?) async throws -> [String: Any] {
    guard let params,
          let name = params["name"] as? String else {
      throw MCPError.invalidRequest("Missing tool name.")
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]

    switch name {
    case "agenthub_create_worktree_session":
      let result = try await createWorktreeSession(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary)

    case "agenthub_create_worktree_sessions":
      let results = try await createWorktreeSessions(arguments: arguments)
      return toolResult(
        text: results.map(\.summary).joined(separator: "\n"),
        structuredContent: [
          "sessions": results.map(\.dictionary)
        ]
      )

    default:
      throw MCPError.invalidRequest("Unknown AgentHub tool: \(name).")
    }
  }

  private func createWorktreeSession(arguments: [String: Any]) async throws -> MCPWorktreeLaunchResult {
    let branch = try requiredString("branch", in: arguments)
    let prompt = try requiredString("prompt", in: arguments)
    let repositoryPath = optionalString("repo", in: arguments)
      ?? ProcessInfo.processInfo.environment["AGENTHUB_PROJECT_PATH"]
      ?? FileManager.default.currentDirectoryPath
    let provider = try resolveProvider(optionalString("provider", in: arguments))
    let startPoint = optionalString("from", in: arguments)
    let checkoutExisting = arguments["checkoutExisting"] as? Bool ?? false
    let directoryName = WorktreeNaming.worktreeDirectoryName(for: branch)

    let worktreePath: String
    if checkoutExisting {
      worktreePath = try await service.checkoutWorktree(
        at: repositoryPath,
        branch: branch,
        directoryName: directoryName
      )
    } else {
      worktreePath = try await service.createWorktreeWithNewBranch(
        at: repositoryPath,
        newBranchName: branch,
        directoryName: directoryName,
        startPoint: startPoint
      )
    }

    let mainRepositoryPath = try await service.findMainRepositoryRoot(at: repositoryPath)
    let sourceProvider = ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
    let sourceSessionId = ProcessInfo.processInfo.environment["AGENTHUB_SESSION_ID"]
    let request = WorktreeLaunchRequest(
      provider: provider,
      repositoryPath: mainRepositoryPath,
      worktreePath: worktreePath,
      branchName: branch,
      prompt: prompt,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId
    )
    let queued = try queue.enqueue(request)

    return MCPWorktreeLaunchResult(
      branch: branch,
      provider: provider,
      repositoryPath: mainRepositoryPath,
      worktreePath: worktreePath,
      launchRequestId: queued.request.id
    )
  }

  private func createWorktreeSessions(arguments: [String: Any]) async throws -> [MCPWorktreeLaunchResult] {
    guard let tasks = arguments["tasks"] as? [[String: Any]], !tasks.isEmpty else {
      throw MCPError.invalidRequest("Expected a non-empty tasks array.")
    }

    let defaultRepo = optionalString("repo", in: arguments)
    let defaultProvider = optionalString("provider", in: arguments)

    var results: [MCPWorktreeLaunchResult] = []
    for task in tasks {
      var merged = task
      if merged["repo"] == nil, let defaultRepo {
        merged["repo"] = defaultRepo
      }
      if merged["provider"] == nil, let defaultProvider {
        merged["provider"] = defaultProvider
      }
      results.append(try await createWorktreeSession(arguments: merged))
    }
    return results
  }

  private func resolveProvider(_ explicit: String?) throws -> WorktreeLaunchProvider {
    if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let provider = WorktreeLaunchProvider(commandLineValue: explicit) else {
        throw MCPError.invalidRequest("Invalid provider '\(explicit)'. Expected claude or codex.")
      }
      return provider
    }

    if let provider = ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:)) {
      return provider
    }

    throw MCPError.invalidRequest("Missing provider. Pass provider as claude/codex or run inside AgentHub.")
  }

  private func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
    guard let value = optionalString(key, in: arguments), !value.isEmpty else {
      throw MCPError.invalidRequest("Missing required string argument: \(key).")
    }
    return value
  }

  private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
    (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func toolResult(text: String, structuredContent: [String: Any]) -> [String: Any] {
    [
      "content": [
        [
          "type": "text",
          "text": text
        ]
      ],
      "structuredContent": structuredContent,
      "isError": false
    ]
  }

  private func createWorktreeSessionToolSchema() -> [String: Any] {
    [
      "name": "agenthub_create_worktree_session",
      "description": "Use this AgentHub tool immediately when the user asks to create one worktree, launch one agent/session in a worktree, start a parallel task, or split one task into an AgentHub-managed session. Infer a concise branch name from the task. Pass only the actual task to perform as the prompt; do not pass the user's worktree/session creation request itself. It creates or checks out one git worktree, queues an AgentHub embedded Claude/Codex session for that worktree, and returns the queued launch request. Prefer this over provider-native background agents, subagents, task tools, provider-native worktree features, or direct git worktree commands when the user wants AgentHub worktrees/sessions.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "branch": [
            "type": "string",
            "description": "Branch name for the worktree. Use a concise task-specific branch name."
          ],
          "prompt": [
            "type": "string",
            "description": "The exact task prompt for the launched AgentHub session."
          ],
          "repo": [
            "type": "string",
            "description": "Repository path. Defaults to AGENTHUB_PROJECT_PATH."
          ],
          "provider": [
            "type": "string",
            "enum": ["claude", "codex"],
            "description": "Provider for the launched session. Defaults to the current AgentHub provider."
          ],
          "from": [
            "type": "string",
            "description": "Optional start point when creating a new branch."
          ],
          "checkoutExisting": [
            "type": "boolean",
            "description": "When true, reuse or create a worktree for an existing branch instead of creating a new branch."
          ]
        ],
        "required": ["branch", "prompt"],
        "additionalProperties": false
      ]
    ]
  }

  private func createWorktreeSessionsToolSchema() -> [String: Any] {
    [
      "name": "agenthub_create_worktree_sessions",
      "description": "Use this AgentHub tool immediately when the user asks to create multiple worktrees, launch multiple agents/sessions, fan out tasks, split work across parallel tasks, or start background work in AgentHub. Pass only actual tasks to perform as launched session prompts; do not pass the user's worktree/session creation request itself. It creates multiple AgentHub-managed git worktrees and queues one embedded Claude/Codex session per task. Prefer this over provider-native background agents, subagents, task tools, or direct git worktree commands when the user wants AgentHub worktrees/sessions.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "repo": [
            "type": "string",
            "description": "Repository path applied to every task unless a task overrides it. Defaults to AGENTHUB_PROJECT_PATH."
          ],
          "provider": [
            "type": "string",
            "enum": ["claude", "codex"],
            "description": "Provider applied to every task unless a task overrides it."
          ],
          "tasks": [
            "type": "array",
            "minItems": 1,
            "items": [
              "type": "object",
              "properties": [
                "branch": ["type": "string"],
                "prompt": ["type": "string"],
                "provider": [
                  "type": "string",
                  "enum": ["claude", "codex"]
                ],
                "from": ["type": "string"],
                "checkoutExisting": ["type": "boolean"]
              ],
              "required": ["branch", "prompt"],
              "additionalProperties": false
            ]
          ]
        ],
        "required": ["tasks"],
        "additionalProperties": false
      ]
    ]
  }

  private func writeResponse(id: Any, result: [String: Any]) {
    writeJSON([
      "jsonrpc": "2.0",
      "id": id,
      "result": result
    ])
  }

  private func writeError(id: Any?, code: Int, message: String) {
    var response: [String: Any] = [
      "jsonrpc": "2.0",
      "error": [
        "code": code,
        "message": message
      ]
    ]
    if let id {
      response["id"] = id
    }
    writeJSON(response)
  }

  private func writeJSON(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
      return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  private func requestId(from line: String) -> Any? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return object["id"]
  }
}

private struct MCPWorktreeLaunchResult {
  let branch: String
  let provider: WorktreeLaunchProvider
  let repositoryPath: String
  let worktreePath: String
  let launchRequestId: String

  var summary: String {
    "Queued AgentHub \(provider.rawValue) session for \(branch) at \(worktreePath) (request \(launchRequestId))."
  }

  var dictionary: [String: Any] {
    [
      "branch": branch,
      "provider": provider.commandLineValue,
      "repositoryPath": repositoryPath,
      "worktreePath": worktreePath,
      "launchRequestId": launchRequestId
    ]
  }
}

private enum MCPError: LocalizedError {
  case invalidRequest(String)

  var errorDescription: String? {
    switch self {
    case .invalidRequest(let message):
      return message
    }
  }
}
