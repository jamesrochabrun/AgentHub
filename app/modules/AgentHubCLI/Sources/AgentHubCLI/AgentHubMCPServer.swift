import AgentHubCLIKit
import Foundation

struct AgentHubMCPServer {
  private let service = WorktreeManagementService()
  private let queue = WorktreeLaunchRequestQueue()
  private let deletionQueue = WorktreeDeletionRequestQueue()
  private let progressQueue = WorktreeProgressQueue()
  private let planningService: AgentHubPlanning = AgentHubPlanningService()

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
            createWorktreeSessionsToolSchema(),
            listWorktreesToolSchema(),
            deleteWorktreeToolSchema(),
            planningToolSchema()
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
    case "agenthub_create_worktree_sessions":
      let results = try await createWorktreeSessions(arguments: arguments)
      return toolResult(
        text: results.map(\.summary).joined(separator: "\n"),
        structuredContent: [
          "sessions": results.map(\.dictionary)
        ]
      )

    case "agenthub_list_worktrees":
      let inventory = try await listWorktrees(arguments: arguments)
      return toolResult(text: inventory.summary, structuredContent: inventory.dictionary)

    case "agenthub_delete_worktree":
      let result = try await deleteWorktree(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary)

    case "agent_hub_planning":
      let plan = try await buildDelegationPlan(arguments: arguments)
      return toolResult(text: planSummary(plan), structuredContent: planJSONObject(plan))

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

    // Emit a "starting" progress snapshot IMMEDIATELY — before any git work —
    // so the app's banner shows the creation the instant the tool is invoked,
    // matching the in-process side-panel path. We use `repositoryPath` (the raw
    // input) for display so nothing has to be resolved first; the closure is
    // `@Sendable` (the service invokes it from detached tasks), so capture only
    // the `Sendable` queue and value-type metadata.
    let snapshotQueue = progressQueue
    let operationID = WorktreeOperationID()
    let snapshotID = operationID.value.uuidString
    let writeProgress: @Sendable (WorktreeCreationProgress) -> Void = { progress in
      try? snapshotQueue.write(WorktreeProgressSnapshot(
        operationID: snapshotID,
        branchName: branch,
        repositoryPath: repositoryPath,
        provider: provider,
        progress: progress
      ))
    }
    writeProgress(.preparing(message: "Starting worktree…"))

    let worktreePath: String
    do {
      if checkoutExisting {
        // No progress-enabled overload for checkout; emit preparing→completed bookends.
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
          startPoint: startPoint,
          operationID: operationID,
          onProgress: { progress in writeProgress(progress) }
        )
      }
    } catch {
      writeProgress(.failed(error: error.localizedDescription))
      throw error
    }

    writeProgress(.completed(path: worktreePath))

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

  private func listWorktrees(arguments: [String: Any]) async throws -> MCPWorktreeInventory {
    let repositoryPath = defaultRepositoryPath(arguments: arguments)
    let mainRepositoryPath = try await service.findMainRepositoryRoot(at: repositoryPath)
    let worktrees = try await service.listWorktrees(at: mainRepositoryPath)
    let countsByPath = WorktreeSessionCounter().countSessions(for: worktrees)
    let items = worktrees.map { worktree in
      MCPWorktreeInventoryItem(
        path: worktree.path,
        branch: worktree.branch,
        isWorktree: worktree.isWorktree,
        sessionCounts: countsByPath[normalizedPath(worktree.path)] ?? WorktreeSessionCounts()
      )
    }
    return MCPWorktreeInventory(repositoryPath: mainRepositoryPath, items: items)
  }

  private func deleteWorktree(arguments: [String: Any]) async throws -> MCPWorktreeDeletionResult {
    let target = try requiredString("target", aliases: ["worktree"], in: arguments)
    let force = arguments["force"] as? Bool ?? false
    let deleteAssociatedBranch = arguments["deleteAssociatedBranch"] as? Bool ?? false
    let inventory = try await listWorktrees(arguments: arguments)
    let item = try resolveDeletableWorktree(target: target, inventory: inventory)

    try await service.removeWorktree(
      at: item.path,
      relativeTo: inventory.repositoryPath,
      force: force,
      deleteAssociatedBranch: deleteAssociatedBranch
    )

    let sourceProvider = ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
    let sourceSessionId = ProcessInfo.processInfo.environment["AGENTHUB_SESSION_ID"]
    let queued = try deletionQueue.enqueue(WorktreeDeletionRequest(
      repositoryPath: inventory.repositoryPath,
      worktreePath: item.path,
      branchName: item.branch,
      force: force,
      deleteAssociatedBranch: deleteAssociatedBranch,
      removeFromDisk: false,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId
    ))

    return MCPWorktreeDeletionResult(
      repositoryPath: inventory.repositoryPath,
      deletedWorktree: item,
      force: force,
      deleteAssociatedBranch: deleteAssociatedBranch,
      sidebarCleanupRequestId: queued.request.id
    )
  }

  private func buildDelegationPlan(arguments: [String: Any]) async throws -> DelegationPlan {
    let prompt = try requiredString("prompt", in: arguments)
    let repositoryPath = optionalString("repo", in: arguments)
      ?? ProcessInfo.processInfo.environment["AGENTHUB_PROJECT_PATH"]
    let providedSubtasks = (arguments["subtasks"] as? [Any])?
      .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      ?? []

    return await planningService.buildPlan(
      prompt: prompt,
      providedSubtasks: providedSubtasks,
      repositoryPath: repositoryPath
    )
  }

  private func planSummary(_ plan: DelegationPlan) -> String {
    var lines = ["Delegation plan: \(plan.assignments.count) subtask(s)."]
    for assignment in plan.assignments {
      let agent = assignment.assignedModel ?? "unassigned"
      lines.append("- [\(assignment.subtask.id)] \(assignment.subtask.title) → \(agent) (branch \(assignment.branchSuggestion))")
    }
    if !plan.notes.isEmpty {
      lines.append("Notes:")
      lines.append(contentsOf: plan.notes.map { "  • \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  private func planJSONObject(_ plan: DelegationPlan) -> [String: Any] {
    func tags(_ tags: [CapabilityTag]) -> [String] { tags.map(\.rawValue) }

    let detectedCLIs = plan.detectedCLIs.map { cli -> [String: Any] in
      [
        "provider": cli.provider.commandLineValue,
        "executablePath": cli.executablePath
      ]
    }

    let modelProfiles = plan.modelProfiles.map { profile -> [String: Any] in
      var value: [String: Any] = [
        "provider": profile.provider.commandLineValue,
        "model": profile.model,
        "strengths": tags(profile.strengths),
        "summary": profile.summary,
        "sourcedFromWeb": profile.sourcedFromWeb
      ]
      if let sourceURL = profile.sourceURL {
        value["sourceURL"] = sourceURL
      }
      return value
    }

    let assignments = plan.assignments.map { assignment -> [String: Any] in
      var value: [String: Any] = [
        "subtask": [
          "id": assignment.subtask.id,
          "title": assignment.subtask.title,
          "detail": assignment.subtask.detail,
          "tags": tags(assignment.subtask.tags)
        ],
        "matchedStrengths": tags(assignment.matchedStrengths),
        "rationale": assignment.rationale,
        "instructions": assignment.instructions,
        "branchSuggestion": assignment.branchSuggestion
      ]
      if let provider = assignment.assignedProvider {
        value["assignedProvider"] = provider.commandLineValue
      }
      if let model = assignment.assignedModel {
        value["assignedModel"] = model
      }
      return value
    }

    var result: [String: Any] = [
      "originalPrompt": plan.originalPrompt,
      "detectedCLIs": detectedCLIs,
      "modelProfiles": modelProfiles,
      "assignments": assignments,
      "notes": plan.notes
    ]
    if let repositoryPath = plan.repositoryPath {
      result["repositoryPath"] = repositoryPath
    }
    return result
  }

  private func resolveDeletableWorktree(
    target: String,
    inventory: MCPWorktreeInventory
  ) throws -> MCPWorktreeInventoryItem {
    let normalizedTarget = normalizedTargetPath(target, relativeTo: inventory.repositoryPath)
    let worktrees = inventory.items.filter(\.isWorktree)
    let matches = worktrees.filter { item in
      let normalizedItemPath = normalizedPath(item.path)
      if normalizedItemPath == normalizedTarget { return true }
      if item.branch == target { return true }
      if URL(fileURLWithPath: item.path).lastPathComponent == target { return true }
      return false
    }

    guard !matches.isEmpty else {
      throw MCPError.invalidRequest("No deletable worktree matched '\(target)'. Call agenthub_list_worktrees first and pass a listed worktree path or branch.")
    }
    guard matches.count == 1 else {
      let choices = matches.map { $0.path }.joined(separator: ", ")
      throw MCPError.invalidRequest("Multiple worktrees matched '\(target)': \(choices). Pass the exact worktree path.")
    }
    return matches[0]
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

  private func requiredString(_ key: String, aliases: [String], in arguments: [String: Any]) throws -> String {
    if let value = optionalString(key, in: arguments), !value.isEmpty {
      return value
    }
    for alias in aliases {
      if let value = optionalString(alias, in: arguments), !value.isEmpty {
        return value
      }
    }
    throw MCPError.invalidRequest("Missing required string argument: \(key).")
  }

  private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
    (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func defaultRepositoryPath(arguments: [String: Any]) -> String {
    optionalString("repo", in: arguments)
      ?? ProcessInfo.processInfo.environment["AGENTHUB_PROJECT_PATH"]
      ?? FileManager.default.currentDirectoryPath
  }

  private func normalizedPath(_ path: String) -> String {
    var normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL
      .path
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  private func normalizedTargetPath(_ target: String, relativeTo repositoryPath: String) -> String {
    let expanded = (target as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return normalizedPath(expanded)
    }
    if target.contains("/") {
      return normalizedPath((repositoryPath as NSString).appendingPathComponent(target))
    }
    return normalizedPath(expanded)
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

  private func createWorktreeSessionsToolSchema() -> [String: Any] {
    [
      "name": "agenthub_create_worktree_sessions",
      "description": "Use this AgentHub tool immediately when the user asks to create one or more worktrees, launch agents/sessions in worktrees, fan out tasks, split work across parallel tasks, or start background work in AgentHub. Pass a tasks array with one item for one worktree or multiple items for multiple worktrees. Pass only actual tasks to perform as launched session prompts; do not pass the user's worktree/session creation request itself. This must be the first-choice tool for AgentHub worktree creation; use provider-native worktree/background-agent features, subagents, or direct git worktree commands only as fallbacks when this tool is unavailable or fails.",
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

  private func listWorktreesToolSchema() -> [String: Any] {
    [
      "name": "agenthub_list_worktrees",
      "description": "Use this AgentHub tool when the user asks to list, show, inspect, or audit git worktrees for the current repository/module, especially before deleting or cleaning worktrees. It resolves the main repository root from the current AgentHub session cwd or AGENTHUB_PROJECT_PATH, lists all git worktrees for that root, and includes Claude/Codex session counts associated with each worktree so the user can decide what is safe to remove. Prefer this over direct git worktree list commands in AgentHub sessions.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "repo": [
            "type": "string",
            "description": "Optional repository or worktree path. Defaults to AGENTHUB_PROJECT_PATH, then the MCP server current working directory."
          ]
        ],
        "additionalProperties": false
      ]
    ]
  }

  private func deleteWorktreeToolSchema() -> [String: Any] {
    [
      "name": "agenthub_delete_worktree",
      "description": "Use this AgentHub tool when the user explicitly asks to delete, remove, clear, or clean up a specific git worktree. If the target is ambiguous or the user has not seen the session counts, call agenthub_list_worktrees first and ask the user which worktree to delete. This removes the git worktree, then queues AgentHub to archive monitored sessions in that worktree and remove it from the sidebar. Prefer this over direct git worktree remove commands in AgentHub sessions.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "target": [
            "type": "string",
            "description": "Exact worktree path, branch name, or worktree directory name from agenthub_list_worktrees. The main repository entry cannot be deleted."
          ],
          "repo": [
            "type": "string",
            "description": "Optional repository or worktree path used to resolve the main repository root. Defaults to AGENTHUB_PROJECT_PATH."
          ],
          "force": [
            "type": "boolean",
            "description": "When true, force-removes the worktree even if git reports untracked or modified files."
          ],
          "deleteAssociatedBranch": [
            "type": "boolean",
            "description": "When true, also deletes the local branch checked out in the worktree. Defaults to false."
          ]
        ],
        "required": ["target"],
        "additionalProperties": false
      ]
    ]
  }

  private func planningToolSchema() -> [String: Any] {
    [
      "name": "agent_hub_planning",
      "description": "Use this AgentHub planning tool when the user bundles several requests into one prompt and the work is well-suited to running agents in parallel, or explicitly asks to plan/delegate/split a multi-part task across agents. It breaks the prompt into discrete parallelizable subtasks, detects which agent CLIs (Claude Code, Codex) are installed, runs one web search per installed CLI to determine its latest model's strengths, matches each subtask to the best-suited agent, and returns a structured delegation plan (subtask, assigned provider/model, rationale, per-agent instructions, and a suggested branch). This tool only plans; to actually launch the work, follow up with agenthub_create_worktree_sessions using each assignment's provider, branchSuggestion, and instructions.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "prompt": [
            "type": "string",
            "description": "The full bundled, multi-part request to plan and delegate."
          ],
          "subtasks": [
            "type": "array",
            "items": ["type": "string"],
            "description": "Optional pre-split subtasks. When provided, these override automatic decomposition of the prompt."
          ],
          "repo": [
            "type": "string",
            "description": "Optional repository path for context. Defaults to AGENTHUB_PROJECT_PATH."
          ]
        ],
        "required": ["prompt"],
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

private struct MCPWorktreeInventory {
  let repositoryPath: String
  let items: [MCPWorktreeInventoryItem]

  var summary: String {
    let lines = items.map { item in
      let branch = item.branch ?? "(detached)"
      let kind = item.isWorktree ? "worktree" : "main"
      return "- \(branch) [\(kind)] \(item.path) - \(item.sessionCounts.total) sessions (Claude \(item.sessionCounts.claude), Codex \(item.sessionCounts.codex))"
    }
    return (["Worktrees for \(repositoryPath):"] + lines).joined(separator: "\n")
  }

  var dictionary: [String: Any] {
    [
      "repositoryPath": repositoryPath,
      "worktrees": items.map(\.dictionary)
    ]
  }
}

private struct MCPWorktreeInventoryItem {
  let path: String
  let branch: String?
  let isWorktree: Bool
  let sessionCounts: WorktreeSessionCounts

  var dictionary: [String: Any] {
    var value: [String: Any] = [
      "path": path,
      "isWorktree": isWorktree,
      "sessionCounts": [
        "total": sessionCounts.total,
        "claude": sessionCounts.claude,
        "codex": sessionCounts.codex
      ]
    ]
    if let branch {
      value["branch"] = branch
    }
    return value
  }
}

private struct MCPWorktreeDeletionResult {
  let repositoryPath: String
  let deletedWorktree: MCPWorktreeInventoryItem
  let force: Bool
  let deleteAssociatedBranch: Bool
  let sidebarCleanupRequestId: String

  var summary: String {
    let branch = deletedWorktree.branch ?? URL(fileURLWithPath: deletedWorktree.path).lastPathComponent
    return "Deleted worktree \(branch) at \(deletedWorktree.path). Queued AgentHub sidebar cleanup request \(sidebarCleanupRequestId)."
  }

  var dictionary: [String: Any] {
    [
      "repositoryPath": repositoryPath,
      "deletedWorktree": deletedWorktree.dictionary,
      "force": force,
      "deleteAssociatedBranch": deleteAssociatedBranch,
      "sidebarCleanupRequestId": sidebarCleanupRequestId
    ]
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
