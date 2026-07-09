import AgentHubCLIKit
import Foundation
import SimulatorPreview

struct AgentHubMCPServer {
  private let service = WorktreeManagementService()
  private let queue = WorktreeLaunchRequestQueue()
  private let deletionQueue = WorktreeDeletionRequestQueue()
  private let progressQueue = WorktreeProgressQueue()
  private let simulatorContextStore = SimulatorSessionContextStore()
  private let simulatorRunQueue = SimulatorRunRequestQueue()
  private let simulatorRunResultStore = SimulatorRunResultStore()
  private let simulatorRecordingService = SimulatorRecordingService()
  private let simctlDeviceLister: any SimctlDeviceListing = SimctlBootedDeviceLister()
  private let simulatorScreenshotService = SimulatorScreenshotService()
  private let simulatorUIDriver = SimulatorUIDriver()

  /// Default bounded wait for a queued Build & Run to finish. Chosen to stay
  /// under the 300s tool-call ceiling so a slow build returns a graceful
  /// "still building — poll with requestId" instead of a hard timeout.
  private static let defaultSimulatorRunWaitSeconds = 240

  /// Hard ceiling on any single `tools/call`. Worktree creation normally
  /// completes in seconds and each underlying `git` invocation has its own
  /// (tighter) timeout, so reaching this bound means a genuine stall rather than
  /// slow-but-healthy work. It is a backstop: rather than leave the calling
  /// agent's tool call hanging indefinitely, we abort and return a recoverable
  /// tool-level error. Override with `AGENTHUB_MCP_TOOL_TIMEOUT_SECONDS`.
  private static let toolCallTimeout: Duration = {
    if let raw = ProcessInfo.processInfo.environment["AGENTHUB_MCP_TOOL_TIMEOUT_SECONDS"],
       let seconds = Int(raw.trimmingCharacters(in: .whitespaces)), seconds > 0
    {
      return .seconds(seconds)
    }
    return .seconds(300)
  }()

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
            let method = object["method"] as? String
      else {
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
            "tools": [:],
          ],
          "serverInfo": [
            "name": "agenthub",
            "version": "1.0.0",
          ],
        ])

      case "tools/list":
        guard let id else { return }
        writeResponse(id: id, result: [
          "tools": [
            createWorktreeSessionsToolSchema(),
            listWorktreesToolSchema(),
            deleteWorktreeToolSchema(),
            planningToolSchema(),
            simulatorStatusToolSchema(),
            simulatorRunToolSchema(),
            simulatorScreenshotToolSchema(),
            simulatorDescribeUIToolSchema(),
            simulatorTapToolSchema(),
            simulatorSwipeToolSchema(),
            simulatorTypeToolSchema(),
            simulatorPressButtonToolSchema(),
            simulatorRecordToolSchema(),
          ],
        ])

      case "tools/call":
        guard let id else { return }
        do {
          let result = try await handleToolCallWithTimeout(params: object["params"] as? [String: Any])
          writeResponse(id: id, result: result)
        } catch let timeout as ToolCallTimedOut {
          // A wedged tool call must never leave the agent hanging. Respond with a
          // tool-level error so the model receives a result it can act on. Any
          // worktrees already created on disk persist and remain discoverable via
          // agenthub_list_worktrees.
          FileHandle.standardError.write(Data(
            "agenthub mcp-server: tool '\(timeout.toolName)' timed out after \(timeout.seconds)s; aborted\n".utf8
          ))
          let recoveryHint = timeout.toolName == "agenthub_simulator_run"
            ? "The Build & Run may still be in progress — call agenthub_simulator_run again with the requestId (or without one after a short wait) to get the outcome."
            : "Any worktrees already created remain on disk — call agenthub_list_worktrees to see them, then retry only the tasks that are still missing."
          writeResponse(id: id, result: toolResult(
            text: "AgentHub tool '\(timeout.toolName)' timed out after \(timeout.seconds) seconds and was aborted. \(recoveryHint)",
            structuredContent: ["timedOut": true, "tool": timeout.toolName],
            isError: true
          ))
        }

      default:
        guard let id else { return }
        writeError(id: id, code: -32601, message: "Method not found: \(method)")
      }
    } catch {
      let id = requestId(from: line)
      writeError(id: id, code: -32000, message: error.localizedDescription)
    }
  }

  /// Signals that a `tools/call` exceeded `toolCallTimeout` and was aborted.
  private struct ToolCallTimedOut: Error {
    let toolName: String
    let seconds: Int
  }

  /// Races `handleToolCall` against `toolCallTimeout`. If the work wins, its
  /// result is returned; if the timeout wins, the work task is cancelled
  /// (propagating to the running `git` process via its cancellation handler) and
  /// `ToolCallTimedOut` is thrown so the caller can answer the agent instead of
  /// hanging. Cancellation is cooperative — this relies on the underlying work
  /// actually honoring `Task` cancellation, which it now does once the EOF
  /// busy-spin in `runGitCommandWithProgress` is removed.
  private func handleToolCallWithTimeout(params: [String: Any]?) async throws -> [String: Any] {
    do {
      return try await withTimeout(Self.toolCallTimeout) {
        try await handleToolCall(params: params)
      }
    } catch is TaskTimeoutError {
      throw ToolCallTimedOut(
        toolName: (params?["name"] as? String) ?? "unknown",
        seconds: Int(Self.toolCallTimeout.components.seconds)
      )
    }
  }

  private func handleToolCall(params: [String: Any]?) async throws -> [String: Any] {
    guard let params,
          let name = params["name"] as? String
    else {
      throw MCPError.invalidRequest("Missing tool name.")
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]

    switch name {
    case "agenthub_create_worktree_sessions":
      let batch = try await createWorktreeSessions(arguments: arguments)
      let summaryLines = batch.successes.map(\.summary) + batch.failures.map(\.summary)
      var structured: [String: Any] = ["sessions": batch.successes.map(\.dictionary)]
      if !batch.failures.isEmpty {
        structured["failures"] = batch.failures.map(\.dictionary)
      }
      // Always return a complete per-task answer — even when some tasks failed —
      // so the caller's tool call never hangs waiting on an all-or-nothing batch.
      return toolResult(
        text: summaryLines.joined(separator: "\n"),
        structuredContent: structured,
        isError: batch.successes.isEmpty
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

    case "agenthub_simulator_status":
      let status = try simulatorStatus(arguments: arguments)
      return toolResult(text: status.summary, structuredContent: status.dictionary)

    case "agenthub_simulator_run":
      let result = try await runSimulator(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary, isError: result.isError)

    case "agenthub_simulator_screenshot":
      let result = try screenshotSimulator(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary)

    case "agenthub_simulator_describe_ui":
      let result = try await describeSimulatorUI(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary)

    case "agenthub_simulator_tap":
      let result = try await tapSimulator(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary)

    case "agenthub_simulator_swipe":
      let result = try await swipeSimulator(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary)

    case "agenthub_simulator_type":
      let result = try typeIntoSimulator(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary)

    case "agenthub_simulator_press_button":
      let result = try pressSimulatorButton(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary)

    case "agenthub_simulator_record":
      let result = try await recordSimulator(arguments: arguments)
      return toolResult(text: result.summary, structuredContent: result.dictionary, isError: result.isError)

    default:
      throw MCPError.invalidRequest("Unknown AgentHub tool: \(name).")
    }
  }

  private func createWorktreeSession(arguments: [String: Any]) async throws -> MCPWorktreeLaunchResult {
    let requestedBranch = try requiredString("branch", in: arguments)
    let prompt = try requiredString("prompt", in: arguments)
    let repositoryPath = optionalString("repo", in: arguments)
      ?? ProcessInfo.processInfo.environment["AGENTHUB_PROJECT_PATH"]
      ?? FileManager.default.currentDirectoryPath
    let provider = try resolveProvider(optionalString("provider", in: arguments))
    let startPoint = optionalString("from", in: arguments)
    let checkoutExisting = arguments["checkoutExisting"] as? Bool ?? false
    let startPath = optionalString("startPath", in: arguments) ?? repositoryPath
    let sparseProfilePaths = try optionalStringArray("sparseProfile", in: arguments)
    let fullCheckout = arguments["fullCheckout"] as? Bool ?? false

    // Proactively avoid name collisions: when creating a NEW branch, derive a
    // free branch/directory name from the existing branches and worktrees so
    // `git worktree add -b` never fails on a name that's already taken (a
    // leftover from a previous run, or a duplicate within the same batch).
    // `checkoutExisting` intentionally reuses an existing branch, so skip it.
    let branch = checkoutExisting
      ? requestedBranch
      : await availableBranchName(requestedBranch, at: repositoryPath)
    let directoryName = WorktreeNaming.worktreeDirectoryName(for: branch)

    // Emit a "starting" progress snapshot IMMEDIATELY — before any git work —
    // so the app's banner shows the creation the instant the tool is invoked,
    // matching the in-process side-panel path. We use `repositoryPath` (the raw
    // input) for display so nothing has to be resolved first; the closure is
    // `@Sendable` (the service invokes it from detached tasks), so capture only
    // the `Sendable` queue and value-type metadata.
    let snapshotQueue = progressQueue
    let snapshotID = UUID().uuidString
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

    let creation: WorktreeCreationLocation
    do {
      if checkoutExisting {
        let worktreePath = try await service.checkoutWorktree(
          at: repositoryPath,
          branch: branch,
          directoryName: directoryName
        )
        let launchPath = try await service.launchPath(
          forStartPath: startPath,
          repoPath: repositoryPath,
          worktreePath: worktreePath
        )
        creation = WorktreeCreationLocation(
          worktreePath: worktreePath,
          launchPath: launchPath,
          isSparseCheckout: false
        )
      } else {
        // Plain, NON-streaming creation. We deliberately avoid the
        // progress-streaming overload (`operationID`/`onProgress`): it pipes git's
        // stderr through an NSFileHandle readabilityHandler that, on EOF, busy-spins
        // the shared `com.apple.NSFileHandle.fd_monitoring` serial queue at 100% CPU
        // and starves `Process.waitUntilExit()` — livelocking the MCP server so the
        // tool call never returns (the original "Stewing…" hang, added in #336).
        // The MCP only needs the coarse preparing→completed snapshots written here
        // for the app's top-bar banner, NOT git's per-file "Updating files" stream,
        // so the simple blocking path (concurrently pipe-drained, timeout-bounded)
        // is both sufficient and robust.
        creation = try await service.createAgentWorktreeWithNewBranch(
          at: repositoryPath,
          startPath: startPath,
          newBranchName: branch,
          directoryName: directoryName,
          startPoint: startPoint,
          sparseProfile: sparseProfilePaths.map { WorktreeSparseCheckoutProfile(paths: $0) },
          fullCheckout: fullCheckout
        )
      }
    } catch {
      writeProgress(.failed(error: error.localizedDescription))
      throw error
    }

    writeProgress(.completed(path: creation.worktreePath))

    let mainRepositoryPath = try await service.findMainRepositoryRoot(at: repositoryPath)
    let sourceProvider = ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
    let sourceSessionId = ProcessInfo.processInfo.environment["AGENTHUB_SESSION_ID"]
    let request = WorktreeLaunchRequest(
      provider: provider,
      repositoryPath: mainRepositoryPath,
      worktreePath: creation.worktreePath,
      launchPath: creation.launchPath == creation.worktreePath ? nil : creation.launchPath,
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
      worktreePath: creation.worktreePath,
      launchPath: creation.launchPath,
      isSparseCheckout: creation.isSparseCheckout,
      sparseCheckoutPaths: creation.sparseCheckoutPaths,
      launchRequestId: queued.request.id
    )
  }

  /// Resolves a non-colliding branch name from the repository's current
  /// branches and worktrees. Best-effort: if git state can't be read, the
  /// requested name is returned unchanged and the per-task error isolation in
  /// `createWorktreeSessions` will surface any resulting failure.
  private func availableBranchName(_ requested: String, at repositoryPath: String) async -> String {
    var takenBranches: Set<String> = []
    var takenDirectoryNames: Set<String> = []

    if let branches = try? await service.getLocalBranches(at: repositoryPath) {
      takenBranches.formUnion(branches.map(\.name))
    }
    if let worktrees = try? await service.listWorktrees(at: repositoryPath) {
      takenBranches.formUnion(worktrees.compactMap(\.branch))
      takenDirectoryNames.formUnion(
        worktrees.map { URL(fileURLWithPath: $0.path).lastPathComponent }
      )
    }

    return WorktreeNaming.availableBranchName(
      for: requested,
      takenBranches: takenBranches,
      takenDirectoryNames: takenDirectoryNames
    )
  }

  private func createWorktreeSessions(arguments: [String: Any]) async throws -> MCPWorktreeBatchResult {
    guard let tasks = arguments["tasks"] as? [[String: Any]], !tasks.isEmpty else {
      throw MCPError.invalidRequest("Expected a non-empty tasks array.")
    }

    let defaultRepo = optionalString("repo", in: arguments)
    let defaultProvider = optionalString("provider", in: arguments)
    let defaultStartPath = optionalString("startPath", in: arguments)
    let defaultSparseProfile = try optionalStringArray("sparseProfile", in: arguments)
    let defaultFullCheckout = arguments["fullCheckout"] as? Bool

    var batch = MCPWorktreeBatchResult()
    for task in tasks {
      var merged = task
      if merged["repo"] == nil, let defaultRepo {
        merged["repo"] = defaultRepo
      }
      if merged["provider"] == nil, let defaultProvider {
        merged["provider"] = defaultProvider
      }
      if merged["startPath"] == nil, let defaultStartPath {
        merged["startPath"] = defaultStartPath
      }
      if merged["sparseProfile"] == nil, let defaultSparseProfile {
        merged["sparseProfile"] = defaultSparseProfile
      }
      if merged["fullCheckout"] == nil, let defaultFullCheckout {
        merged["fullCheckout"] = defaultFullCheckout
      }

      // Isolate per-task failures: one bad task (invalid args, a git error)
      // must not abort the whole batch. Every worktree that was created on disk
      // still gets enqueued and reported, and a failed task surfaces an error
      // entry instead of leaving the caller hanging. createWorktreeSession has
      // already emitted a `.failed` progress snapshot before throwing.
      do {
        batch.successes.append(try await createWorktreeSession(arguments: merged))
      } catch {
        let branch = optionalString("branch", in: merged) ?? "(unknown)"
        batch.failures.append(MCPWorktreeTaskFailure(
          branch: branch,
          message: error.localizedDescription
        ))
      }
    }
    return batch
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

    let planner = AgentHubPlanningService()

    return await planner.buildPlan(
      prompt: prompt,
      providedSubtasks: providedSubtasks,
      repositoryPath: repositoryPath
    )
  }

  private func simulatorStatus(arguments: [String: Any]) throws -> MCPSimulatorStatusResult {
    let context = try simulatorContextStore.resolveContext(
      provider: requestedSourceProvider(arguments: arguments),
      sessionId: optionalString("sessionId", in: arguments) ?? sourceSessionId,
      projectPath: simulatorProjectPath(arguments: arguments)
    )
    let contexts = try simulatorContextStore.contexts()
    // Live simctl truth alongside the panel-written contexts: contexts go
    // stale after a crash and don't exist when no panel is open.
    let bootedDevices = simctlDeviceLister.bootedDevices()
    return MCPSimulatorStatusResult(
      activeContext: context,
      contexts: contexts,
      bootedDevices: bootedDevices
    )
  }

  private func runSimulator(arguments: [String: Any]) async throws -> MCPSimulatorRunResult {
    let waitSeconds = simulatorRunWaitSeconds(arguments: arguments)

    // Poll mode: report the outcome of a previously queued run.
    if let requestId = optionalString("requestId", in: arguments), !requestId.isEmpty {
      return await simulatorRunOutcome(
        requestId: requestId,
        target: nil,
        waitSeconds: waitSeconds
      )
    }

    let target = try resolveSimulatorRunTarget(arguments: arguments)
    guard let projectPath = target.projectPath else {
      throw MCPError.invalidRequest("Missing simulator project path.")
    }
    let request = SimulatorRunRequest(
      projectPath: projectPath,
      udid: target.udid,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId,
      reason: optionalString("reason", in: arguments)
    )
    let queued = try simulatorRunQueue.enqueue(request)

    guard waitSeconds > 0 else {
      return .queued(requestID: queued.request.id, target: target)
    }
    return await simulatorRunOutcome(
      requestId: queued.request.id,
      target: target,
      waitSeconds: waitSeconds
    )
  }

  /// Waits (bounded) for the app to write the run's terminal result, falling
  /// back to queue-file state so the agent always gets an actionable answer.
  private func simulatorRunOutcome(
    requestId: String,
    target: MCPSimulatorTarget?,
    waitSeconds: Int
  ) async -> MCPSimulatorRunResult {
    let result: SimulatorRunResult?
    if waitSeconds > 0 {
      result = await simulatorRunResultStore.waitForResult(
        requestId: requestId,
        timeout: .seconds(waitSeconds)
      )
    } else {
      result = simulatorRunResultStore.result(requestId: requestId)
    }
    if let result {
      return .finished(result)
    }

    let pendingURL = simulatorRunQueue.directoryURL
      .appendingPathComponent("\(requestId).json", isDirectory: false)
    if FileManager.default.fileExists(atPath: pendingURL.path) {
      return .stillRunning(requestID: requestId, target: target, waitedSeconds: waitSeconds)
    }
    let failedURL = simulatorRunQueue.directoryURL
      .appendingPathComponent("\(requestId).failed", isDirectory: false)
    if FileManager.default.fileExists(atPath: failedURL.path) {
      return .failedWithoutDetail(requestID: requestId, target: target)
    }
    return .unknownRequest(requestID: requestId)
  }

  private func simulatorRunWaitSeconds(arguments: [String: Any]) -> Int {
    let requested = (arguments["waitSeconds"] as? NSNumber)?.intValue
      ?? Self.defaultSimulatorRunWaitSeconds
    return min(max(requested, 0), 3600)
  }

  /// Target resolution for Build & Run: explicit udid → live panel context →
  /// project-only (the app resolves the project's persisted destination).
  private func resolveSimulatorRunTarget(arguments: [String: Any]) throws -> MCPSimulatorTarget {
    let explicitProjectPath = simulatorProjectPath(arguments: arguments)
    if let explicitUDID = optionalString("udid", in: arguments), !explicitUDID.isEmpty {
      guard let projectPath = explicitProjectPath, !projectPath.isEmpty else {
        throw MCPError.invalidRequest("Pass projectPath/repo when using an explicit simulator udid.")
      }
      return MCPSimulatorTarget(udid: explicitUDID, projectPath: projectPath, context: nil)
    }

    if let context = try? simulatorContextStore.resolveContext(
      provider: requestedSourceProvider(arguments: arguments),
      sessionId: optionalString("sessionId", in: arguments) ?? sourceSessionId,
      projectPath: explicitProjectPath
    ) {
      return MCPSimulatorTarget(udid: context.udid, projectPath: context.projectPath, context: context)
    }

    if let projectPath = explicitProjectPath, !projectPath.isEmpty {
      // No panel context — let the app resolve the project's saved simulator
      // preference. If none exists the run result reports that clearly.
      return MCPSimulatorTarget(udid: nil, projectPath: projectPath, context: nil)
    }

    throw MCPError.invalidRequest(
      "No project path or AgentHub simulator context was found. Pass projectPath/repo, or open the Simulator panel for this session."
    )
  }

  /// Resolves a concrete booted/known device for read-only tools (screenshot,
  /// describe UI, recording): explicit udid → panel context → the single
  /// booted simulator.
  private func resolveConcreteSimulatorDevice(arguments: [String: Any]) throws -> MCPSimulatorTarget {
    let explicitProjectPath = simulatorProjectPath(arguments: arguments)
    if let explicitUDID = optionalString("udid", in: arguments), !explicitUDID.isEmpty {
      return MCPSimulatorTarget(udid: explicitUDID, projectPath: explicitProjectPath, context: nil)
    }

    if let context = try? simulatorContextStore.resolveContext(
      provider: requestedSourceProvider(arguments: arguments),
      sessionId: optionalString("sessionId", in: arguments) ?? sourceSessionId,
      projectPath: explicitProjectPath
    ) {
      return MCPSimulatorTarget(udid: context.udid, projectPath: context.projectPath, context: context)
    }

    let booted = simctlDeviceLister.bootedDevices()
    if booted.count == 1, let device = booted.first {
      return MCPSimulatorTarget(udid: device.udid, projectPath: explicitProjectPath, context: nil)
    }
    if booted.isEmpty {
      throw MCPError.invalidRequest(
        "No booted simulator and no AgentHub Simulator panel context was found. Boot a simulator (or run agenthub_simulator_run) first, or pass an explicit udid."
      )
    }
    throw MCPError.invalidRequest(
      "Multiple simulators are booted (\(booted.map { "\($0.name) \($0.udid)" }.joined(separator: ", "))). Pass an explicit udid."
    )
  }

  private func screenshotSimulator(arguments: [String: Any]) throws -> MCPSimulatorScreenshotResult {
    let target = try resolveConcreteSimulatorDevice(arguments: arguments)
    guard let udid = target.udid else {
      throw MCPError.invalidRequest("Could not resolve a simulator udid for the screenshot.")
    }
    let outputDirectory = optionalString("outputDirectory", in: arguments).map {
      URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    }
    let outputURL = try simulatorScreenshotService.capture(
      udid: udid,
      outputDirectory: outputDirectory,
      fileName: optionalString("fileName", in: arguments)
    )
    return MCPSimulatorScreenshotResult(target: target, outputPath: outputURL.path)
  }

  private func describeSimulatorUI(arguments: [String: Any]) async throws -> MCPSimulatorDescribeUIResult {
    let target = try resolveConcreteSimulatorDevice(arguments: arguments)
    guard let udid = target.udid else {
      throw MCPError.invalidRequest("Could not resolve a simulator udid to inspect.")
    }
    let tree = try await fetchAccessibilityTree(udid: udid)
    return MCPSimulatorDescribeUIResult(
      target: target,
      elementCount: tree.flattened().count,
      treeText: SimulatorAXTreeTextRenderer.render(tree)
    )
  }

  private func fetchAccessibilityTree(udid: String) async throws -> SimulatorAXElement {
    let developerDir = XcodeDeveloperDirectory.resolved
    let inspector = SimulatorAXInspector.shared
    guard inspector.isAvailable(developerDir: developerDir) else {
      throw MCPError.invalidRequest(
        "Accessibility inspection is unavailable on this machine (AccessibilityPlatformTranslation framework not found). Use agenthub_simulator_screenshot instead."
      )
    }
    do {
      return try await inspector.fetchFrontmostTree(udid: udid, developerDir: developerDir)
    } catch {
      throw MCPError.invalidRequest(
        "Failed to read the simulator's accessibility tree: \(error.localizedDescription). The device must be booted with the app in the foreground; a screenshot may work as a fallback."
      )
    }
  }

  /// Interaction requires a live device; sending HID events into a shut-down
  /// device silently does nothing, so fail loudly up front instead.
  private func ensureSimulatorBooted(udid: String) throws {
    guard simctlDeviceLister.bootedDevices().contains(where: { $0.udid == udid }) else {
      throw MCPError.invalidRequest(
        "Simulator \(udid) is not booted. Run agenthub_simulator_run first (it boots the device and launches the app), then retry."
      )
    }
  }

  private func tapSimulator(arguments: [String: Any]) async throws -> MCPSimulatorInteractionResult {
    let target = try resolveConcreteSimulatorDevice(arguments: arguments)
    guard let udid = target.udid else {
      throw MCPError.invalidRequest("Could not resolve a simulator udid to tap.")
    }
    try ensureSimulatorBooted(udid: udid)
    let holdSeconds = (arguments["holdSeconds"] as? NSNumber)?.doubleValue ?? 0

    let label = optionalString("label", in: arguments)
    let identifier = optionalString("identifier", in: arguments)
    if label != nil || identifier != nil {
      let tree = try await fetchAccessibilityTree(udid: udid)
      let matches = SimulatorAXElementFinder.matches(in: tree, label: label, identifier: identifier)
      let query = [identifier.map { "identifier \"\($0)\"" }, label.map { "label \"\($0)\"" }]
        .compactMap { $0 }.joined(separator: " / ")

      guard !matches.isEmpty else {
        throw MCPError.invalidRequest(
          "No tappable element matched \(query). Call agenthub_simulator_describe_ui to see what is on screen — the app may still be on a different screen or animating."
        )
      }
      let occurrence = (arguments["occurrence"] as? NSNumber)?.intValue
      if matches.count > 1, occurrence == nil {
        let listing = matches.prefix(8).enumerated().map { index, element in
          "\(index + 1). \(element.summary) \(SimulatorAXTreeTextRenderer.frameDescription(element.frame))"
        }.joined(separator: "\n")
        throw MCPError.invalidRequest(
          "\(matches.count) elements matched \(query) — pass occurrence (1-based, top-to-bottom document order):\n\(listing)"
        )
      }
      let index = (occurrence ?? 1) - 1
      guard matches.indices.contains(index) else {
        throw MCPError.invalidRequest(
          "occurrence \(occurrence ?? 0) is out of range — only \(matches.count) element(s) matched \(query)."
        )
      }
      let element = matches[index]
      guard let normalized = SimulatorUIDriver.normalizedPoint(
        x: element.frame.midX, y: element.frame.midY, screenSize: tree.frame.size
      ) else {
        throw MCPError.invalidRequest("The matched element has a degenerate frame; tap by x/y instead.")
      }
      try simulatorUIDriver.tap(
        udid: udid, normalizedX: normalized.x, normalizedY: normalized.y, holdSeconds: holdSeconds
      )
      return MCPSimulatorInteractionResult(
        action: "tap",
        target: target,
        detail: "Tapped \(element.summary) at (\(Int(element.frame.midX)), \(Int(element.frame.midY))) pt."
      )
    }

    guard let x = (arguments["x"] as? NSNumber)?.doubleValue,
          let y = (arguments["y"] as? NSNumber)?.doubleValue
    else {
      throw MCPError.invalidRequest("Pass label/identifier to tap an element, or x and y coordinates.")
    }
    let normalized: CGPoint
    if (arguments["normalized"] as? Bool) == true {
      normalized = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    } else {
      let tree = try await fetchAccessibilityTree(udid: udid)
      guard let point = SimulatorUIDriver.normalizedPoint(x: x, y: y, screenSize: tree.frame.size) else {
        throw MCPError.invalidRequest("Could not determine the screen size to convert points; pass normalized: true with 0-1 coordinates.")
      }
      normalized = point
    }
    try simulatorUIDriver.tap(
      udid: udid, normalizedX: normalized.x, normalizedY: normalized.y, holdSeconds: holdSeconds
    )
    return MCPSimulatorInteractionResult(
      action: "tap",
      target: target,
      detail: "Tapped at (\(x), \(y))\((arguments["normalized"] as? Bool) == true ? " normalized" : " pt")."
    )
  }

  private func swipeSimulator(arguments: [String: Any]) async throws -> MCPSimulatorInteractionResult {
    let target = try resolveConcreteSimulatorDevice(arguments: arguments)
    guard let udid = target.udid else {
      throw MCPError.invalidRequest("Could not resolve a simulator udid to swipe.")
    }
    try ensureSimulatorBooted(udid: udid)
    let duration = (arguments["durationSeconds"] as? NSNumber)?.doubleValue ?? 0.3

    if let direction = optionalString("direction", in: arguments), !direction.isEmpty {
      guard let preset = SimulatorUIDriver.swipePreset(direction: direction) else {
        throw MCPError.invalidRequest("Invalid swipe direction '\(direction)'. Expected up, down, left, or right.")
      }
      try simulatorUIDriver.swipe(udid: udid, from: preset.from, to: preset.to, durationSeconds: duration)
      return MCPSimulatorInteractionResult(
        action: "swipe",
        target: target,
        detail: "Swiped \(direction.lowercased()) (finger direction; content moves the opposite way)."
      )
    }

    guard let fromX = (arguments["fromX"] as? NSNumber)?.doubleValue,
          let fromY = (arguments["fromY"] as? NSNumber)?.doubleValue,
          let toX = (arguments["toX"] as? NSNumber)?.doubleValue,
          let toY = (arguments["toY"] as? NSNumber)?.doubleValue
    else {
      throw MCPError.invalidRequest("Pass direction (up/down/left/right), or fromX/fromY/toX/toY coordinates.")
    }

    let from: CGPoint
    let to: CGPoint
    if (arguments["normalized"] as? Bool) == true {
      from = CGPoint(x: min(max(fromX, 0), 1), y: min(max(fromY, 0), 1))
      to = CGPoint(x: min(max(toX, 0), 1), y: min(max(toY, 0), 1))
    } else {
      let tree = try await fetchAccessibilityTree(udid: udid)
      guard let fromPoint = SimulatorUIDriver.normalizedPoint(x: fromX, y: fromY, screenSize: tree.frame.size),
            let toPoint = SimulatorUIDriver.normalizedPoint(x: toX, y: toY, screenSize: tree.frame.size)
      else {
        throw MCPError.invalidRequest("Could not determine the screen size to convert points; pass normalized: true with 0-1 coordinates.")
      }
      from = fromPoint
      to = toPoint
    }
    try simulatorUIDriver.swipe(udid: udid, from: from, to: to, durationSeconds: duration)
    return MCPSimulatorInteractionResult(
      action: "swipe",
      target: target,
      detail: "Swiped from (\(fromX), \(fromY)) to (\(toX), \(toY))."
    )
  }

  private func typeIntoSimulator(arguments: [String: Any]) throws -> MCPSimulatorInteractionResult {
    let target = try resolveConcreteSimulatorDevice(arguments: arguments)
    guard let udid = target.udid else {
      throw MCPError.invalidRequest("Could not resolve a simulator udid to type into.")
    }
    try ensureSimulatorBooted(udid: udid)

    let text = optionalString("text", in: arguments)
    let key = optionalString("key", in: arguments)
    if let key, !key.isEmpty {
      guard let usage = SimulatorUIDriver.keyUsage(named: key) else {
        throw MCPError.invalidRequest("Unknown key '\(key)'. Expected return, delete, escape, tab, space, up, down, left, or right.")
      }
      let times = (arguments["times"] as? NSNumber)?.intValue ?? 1
      do {
        try simulatorUIDriver.pressKey(udid: udid, usage: usage, times: times)
      } catch {
        throw MCPError.invalidRequest(error.localizedDescription)
      }
      return MCPSimulatorInteractionResult(
        action: "type",
        target: target,
        detail: "Pressed \(key)\(times > 1 ? " ×\(times)" : "")."
      )
    }

    guard let text, !text.isEmpty else {
      throw MCPError.invalidRequest("Pass text to type, or key (return/delete/escape/tab/space/arrows).")
    }
    do {
      try simulatorUIDriver.typeText(udid: udid, text: text)
    } catch {
      throw MCPError.invalidRequest(error.localizedDescription)
    }
    return MCPSimulatorInteractionResult(
      action: "type",
      target: target,
      detail: "Typed \(text.count) character(s). A text field must have been focused (tap it first) for input to land."
    )
  }

  private func pressSimulatorButton(arguments: [String: Any]) throws -> MCPSimulatorInteractionResult {
    let target = try resolveConcreteSimulatorDevice(arguments: arguments)
    guard let udid = target.udid else {
      throw MCPError.invalidRequest("Could not resolve a simulator udid.")
    }
    try ensureSimulatorBooted(udid: udid)

    let name = (optionalString("button", in: arguments) ?? "").lowercased()
    let button: SimulatorHardwareButton
    switch name {
    case "home": button = .home
    case "swipehome", "swipe-home": button = .swipeHome
    case "lock": button = .lock
    case "appswitcher", "app-switcher": button = .appSwitcher
    default:
      throw MCPError.invalidRequest("Invalid button '\(name)'. Expected home, swipeHome, lock, or appSwitcher.")
    }
    do {
      try simulatorUIDriver.pressButton(udid: udid, button: button)
    } catch {
      throw MCPError.invalidRequest(error.localizedDescription)
    }
    return MCPSimulatorInteractionResult(
      action: "press_button",
      target: target,
      detail: "Pressed \(name)."
    )
  }

  private func recordSimulator(arguments: [String: Any]) async throws -> MCPSimulatorRecordResult {
    let action = (optionalString("action", in: arguments) ?? "start").lowercased()
    let target = try resolveConcreteSimulatorDevice(arguments: arguments)
    guard let udid = target.udid else {
      throw MCPError.invalidRequest("Could not resolve a simulator udid to record.")
    }

    switch action {
    case "start":
      let outputDirectory = optionalString("outputDirectory", in: arguments).map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
      }
      let started = try await simulatorRecordingService.startRecording(
        udid: udid,
        outputDirectory: outputDirectory,
        fileName: optionalString("fileName", in: arguments)
      )
      return .started(started, target: target)

    case "stop":
      let result = try await simulatorRecordingService.stopRecording(udid: udid)
      return .stopped(result, target: target)

    default:
      throw MCPError.invalidRequest("Invalid simulator recording action '\(action)'. Expected start or stop.")
    }
  }

  private var sourceProvider: WorktreeLaunchProvider? {
    ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
  }

  private var sourceSessionId: String? {
    ProcessInfo.processInfo.environment["AGENTHUB_SESSION_ID"]
  }

  private func requestedSourceProvider(arguments: [String: Any]) -> WorktreeLaunchProvider? {
    optionalString("provider", in: arguments)
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
      ?? sourceProvider
  }

  private func simulatorProjectPath(arguments: [String: Any]) -> String? {
    optionalString("projectPath", in: arguments)
      ?? optionalString("repo", in: arguments)
      ?? ProcessInfo.processInfo.environment["AGENTHUB_PROJECT_PATH"]
  }

  private func planSummary(_ plan: DelegationPlan) -> String {
    var lines = ["Delegation plan: \(plan.assignments.count) subtask(s)."]
    for assignment in plan.assignments {
      let agent = assignment.assignedProvider?.harnessName ?? "your choice (Claude Code or Codex)"
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
        "harness": cli.provider.harnessName,
        "executablePath": cli.executablePath,
      ]
    }

    let harnessCapabilities = plan.harnessCapabilities.map { capability -> [String: Any] in
      [
        "provider": capability.provider.commandLineValue,
        "harness": capability.provider.harnessName,
        "skills": capability.skills.map { ["name": $0.name, "description": $0.description] },
        "mcpServers": capability.mcpServers,
      ]
    }

    let assignments = plan.assignments.map { assignment -> [String: Any] in
      var value: [String: Any] = [
        "subtask": [
          "id": assignment.subtask.id,
          "title": assignment.subtask.title,
          "detail": assignment.subtask.detail,
          "tags": tags(assignment.subtask.tags),
        ],
        "rationale": assignment.rationale,
        "instructions": assignment.instructions,
        "branchSuggestion": assignment.branchSuggestion,
      ]
      if let provider = assignment.assignedProvider {
        value["assignedProvider"] = provider.commandLineValue
        value["assignedHarness"] = provider.harnessName
      }
      if !assignment.matchedCapabilities.isEmpty {
        value["matchedCapabilities"] = assignment.matchedCapabilities
      }
      return value
    }

    var result: [String: Any] = [
      "originalPrompt": plan.originalPrompt,
      "detectedCLIs": detectedCLIs,
      "harnessCapabilities": harnessCapabilities,
      "assignments": assignments,
      "notes": plan.notes,
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
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
    {
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

  private func optionalStringArray(_ key: String, in arguments: [String: Any]) throws -> [String]? {
    guard let rawValue = arguments[key] else { return nil }
    guard let values = rawValue as? [String] else {
      throw MCPError.invalidRequest("Expected \(key) to be an array of strings.")
    }

    let trimmed = values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return trimmed.isEmpty ? nil : trimmed
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

  private func toolResult(
    text: String,
    structuredContent: [String: Any],
    isError: Bool = false
  ) -> [String: Any] {
    [
      "content": [
        [
          "type": "text",
          "text": text,
        ],
      ],
      "structuredContent": structuredContent,
      "isError": isError,
    ]
  }

  private func createWorktreeSessionsToolSchema() -> [String: Any] {
    [
      "name": "agenthub_create_worktree_sessions",
      "description": "Creates AgentHub-managed git worktree sessions from task objects. Each task requires an explicit provider, branch, and prompt. By default, subdirectory starts create sparse checkouts inferred from project markers near startPath; pass fullCheckout only when a full materialized repo is explicitly required.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "repo": [
            "type": "string",
            "description": "Repository path applied to every task unless a task overrides it. Defaults to AGENTHUB_PROJECT_PATH.",
          ],
          "startPath": [
            "type": "string",
            "description": "Agent launch directory applied to every task unless a task overrides it. Must be inside repo; defaults to the task repo. Non-root start paths infer sparse checkout from nearby project markers.",
          ],
          "sparseProfile": [
            "type": "array",
            "items": ["type": "string"],
            "description": "Explicit sparse-checkout paths applied to every new worktree unless a task overrides them. Defaults to a profile inferred from project markers near startPath.",
          ],
          "fullCheckout": [
            "type": "boolean",
            "description": "Explicit fallback that disables sparse checkout and materializes the full repository for new worktrees. Defaults to false.",
          ],
          "provider": [
            "type": "string",
            "enum": ["claude", "codex"],
            "description": "Provider applied to every task unless a task overrides it.",
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
                  "enum": ["claude", "codex"],
                  "description": "Agent/provider assigned to this task.",
                ],
                "from": ["type": "string"],
                "startPath": [
                  "type": "string",
                  "description": "Agent launch directory for this task. Must be inside repo; used to infer the sparse profile from nearby project markers and launch cwd.",
                ],
                "sparseProfile": [
                  "type": "array",
                  "items": ["type": "string"],
                  "description": "Explicit sparse-checkout paths for this task.",
                ],
                "fullCheckout": [
                  "type": "boolean",
                  "description": "When true, disables sparse checkout for this task.",
                ],
                "checkoutExisting": ["type": "boolean"],
              ],
              "required": ["branch", "prompt", "provider"],
              "additionalProperties": false,
            ],
          ],
        ],
        "required": ["tasks"],
        "additionalProperties": false,
      ],
    ]
  }

  private func listWorktreesToolSchema() -> [String: Any] {
    [
      "name": "agenthub_list_worktrees",
      "description": "Lists git worktrees for an AgentHub repository. Resolves the main repository root from the current session cwd or AGENTHUB_PROJECT_PATH and includes Claude/Codex session counts associated with each worktree.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "repo": [
            "type": "string",
            "description": "Optional repository or worktree path. Defaults to AGENTHUB_PROJECT_PATH, then the MCP server current working directory.",
          ],
        ],
        "additionalProperties": false,
      ],
    ]
  }

  private func deleteWorktreeToolSchema() -> [String: Any] {
    [
      "name": "agenthub_delete_worktree",
      "description": "Removes a specified AgentHub-managed git worktree, then queues AgentHub to archive monitored sessions in that worktree and remove it from the sidebar.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "target": [
            "type": "string",
            "description": "Exact worktree path, branch name, or worktree directory name from agenthub_list_worktrees. The main repository entry cannot be deleted.",
          ],
          "repo": [
            "type": "string",
            "description": "Optional repository or worktree path used to resolve the main repository root. Defaults to AGENTHUB_PROJECT_PATH.",
          ],
          "force": [
            "type": "boolean",
            "description": "When true, force-removes the worktree even if git reports untracked or modified files.",
          ],
          "deleteAssociatedBranch": [
            "type": "boolean",
            "description": "When true, also deletes the local branch checked out in the worktree. Defaults to false.",
          ],
        ],
        "required": ["target"],
        "additionalProperties": false,
      ],
    ]
  }

  private func planningToolSchema() -> [String: Any] {
    [
      "name": "agent_hub_planning",
      "description": "Builds an advisory plan for AgentHub task delegation. AgentHub launches an agent HARNESS (Claude Code or Codex) — it cannot pick or configure a model — so the plan only ever names the harness, never a model. Decomposition is YOUR job: pass the independent subtasks you inferred; when omitted, the whole prompt is treated as a single task (AgentHub does not statically split). Returns each detected harness's REAL capabilities (its installed skills + configured MCP servers) under `harnessCapabilities`. When one harness is installed it is assigned; when more than one is installed each subtask is SUGGESTED the harness whose skills/MCP tools best match it (see each assignment's `matchedCapabilities`) — confirm or override using that real capability data rather than the harness's general reputation. Advisory only.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "prompt": [
            "type": "string",
            "description": "The full bundled, multi-part request to plan and delegate.",
          ],
          "subtasks": [
            "type": "array",
            "items": ["type": "string"],
            "description": "The independent subtasks you inferred from the request, one entry per task. When omitted, AgentHub plans the whole prompt as a single task — it never statically splits prose or lists.",
          ],
          "repo": [
            "type": "string",
            "description": "Optional repository path for context. Defaults to AGENTHUB_PROJECT_PATH.",
          ],
        ],
        "required": ["prompt"],
        "additionalProperties": false,
      ],
    ]
  }

  private func simulatorStatusToolSchema() -> [String: Any] {
    [
      "name": "agenthub_simulator_status",
      "description": "Returns the iOS Simulator target AgentHub associates with this agent session/project (the Simulator panel context when one is open) plus the LIVE list of booted simulators from simctl. Use this first so build/verify steps target the same device the user is viewing.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "sessionId": [
            "type": "string",
            "description": "Optional AgentHub session id. Defaults to AGENTHUB_SESSION_ID.",
          ],
          "provider": [
            "type": "string",
            "enum": ["claude", "codex"],
            "description": "Optional provider used to disambiguate the session.",
          ],
          "projectPath": [
            "type": "string",
            "description": "Optional project path. Defaults to AGENTHUB_PROJECT_PATH.",
          ],
          "repo": [
            "type": "string",
            "description": "Alias for projectPath.",
          ],
        ],
        "additionalProperties": false,
      ],
    ]
  }

  private func simulatorRunToolSchema() -> [String: Any] {
    [
      "name": "agenthub_simulator_run",
      "description": "Builds & relaunches the project on its AgentHub simulator destination and WAITS for the outcome — failures return the build error text so you can fix and retry. ALWAYS prefer this over invoking xcodebuild yourself: a raw `xcodebuild build` only proves the code compiles — it neither updates nor verifies the app the user is watching. Call this after finishing a batch of code changes; no panel needs to be open (the app resolves the project's saved run destination). Skip it only when a previous result reported hotReloadArmed=true and you changed existing Swift files only — those hot-swap automatically. After a successful run, navigate to the changed screen with agenthub_simulator_tap/swipe (a relaunch starts the app fresh) and verify with agenthub_simulator_screenshot or agenthub_simulator_describe_ui.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "udid": [
            "type": "string",
            "description": "Optional simulator UDID. Defaults to the AgentHub Simulator panel target, then the project's saved run destination.",
          ],
          "projectPath": [
            "type": "string",
            "description": "Optional Xcode project repository path. Defaults to the panel context or AGENTHUB_PROJECT_PATH.",
          ],
          "repo": [
            "type": "string",
            "description": "Alias for projectPath.",
          ],
          "sessionId": [
            "type": "string",
            "description": "Optional AgentHub session id. Defaults to AGENTHUB_SESSION_ID.",
          ],
          "reason": [
            "type": "string",
            "description": "Short note explaining why the run was requested.",
          ],
          "waitSeconds": [
            "type": "integer",
            "description": "How long to wait for the build outcome (default 240, max 3600). Pass 0 to queue without waiting.",
          ],
          "requestId": [
            "type": "string",
            "description": "Poll a previously queued run instead of starting a new one — returns its outcome or keeps waiting up to waitSeconds.",
          ],
        ],
        "additionalProperties": false,
      ],
    ]
  }

  private func simulatorScreenshotToolSchema() -> [String: Any] {
    [
      "name": "agenthub_simulator_screenshot",
      "description": "Captures a PNG screenshot of the booted iOS Simulator and returns the file path — read the file to verify a UI change actually looks right. Targets the AgentHub Simulator panel device, falling back to the single booted simulator. Use after agenthub_simulator_run (or a hot reload) as the visual step of the verify loop.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "udid": [
            "type": "string",
            "description": "Optional simulator UDID. Defaults to the AgentHub Simulator panel target, then the single booted simulator.",
          ],
          "sessionId": [
            "type": "string",
            "description": "Optional AgentHub session id. Defaults to AGENTHUB_SESSION_ID.",
          ],
          "projectPath": [
            "type": "string",
            "description": "Optional project path used only to resolve the panel context.",
          ],
          "repo": [
            "type": "string",
            "description": "Alias for projectPath.",
          ],
          "outputDirectory": [
            "type": "string",
            "description": "Optional directory for the PNG. Defaults to a temp directory.",
          ],
          "fileName": [
            "type": "string",
            "description": "Optional output filename. .png is appended when omitted.",
          ],
        ],
        "additionalProperties": false,
      ],
    ]
  }

  private func simulatorDescribeUIToolSchema() -> [String: Any] {
    [
      "name": "agenthub_simulator_describe_ui",
      "description": "Reads the accessibility tree of the frontmost app on the booted iOS Simulator and returns it as indented text (role, label, identifier, value, frame in device points). Use it to verify structure precisely — element presence, labels, layout positions — where a screenshot is ambiguous, and to find the labels/identifiers that agenthub_simulator_tap targets when navigating the app. Complements agenthub_simulator_screenshot in the verify loop.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "udid": [
            "type": "string",
            "description": "Optional simulator UDID. Defaults to the AgentHub Simulator panel target, then the single booted simulator.",
          ],
          "sessionId": [
            "type": "string",
            "description": "Optional AgentHub session id. Defaults to AGENTHUB_SESSION_ID.",
          ],
          "projectPath": [
            "type": "string",
            "description": "Optional project path used only to resolve the panel context.",
          ],
          "repo": [
            "type": "string",
            "description": "Alias for projectPath.",
          ],
        ],
        "additionalProperties": false,
      ],
    ]
  }

  /// Shared device-resolution properties for the read-only/interaction tools.
  private func simulatorDeviceProperties() -> [String: Any] {
    [
      "udid": [
        "type": "string",
        "description": "Optional simulator UDID. Defaults to the AgentHub Simulator panel target, then the single booted simulator.",
      ],
      "sessionId": [
        "type": "string",
        "description": "Optional AgentHub session id. Defaults to AGENTHUB_SESSION_ID.",
      ],
      "projectPath": [
        "type": "string",
        "description": "Optional project path used only to resolve the panel context.",
      ],
      "repo": [
        "type": "string",
        "description": "Alias for projectPath.",
      ],
    ]
  }

  private func simulatorTapToolSchema() -> [String: Any] {
    var properties = simulatorDeviceProperties()
    properties["label"] = [
      "type": "string",
      "description": "Tap the element with this accessibility label (from agenthub_simulator_describe_ui). Exact match preferred, then case-insensitive, then substring.",
    ]
    properties["identifier"] = [
      "type": "string",
      "description": "Tap the element with this accessibility identifier.",
    ]
    properties["occurrence"] = [
      "type": "integer",
      "description": "1-based pick when several elements match the label/identifier (document order).",
    ]
    properties["x"] = [
      "type": "number",
      "description": "X coordinate in device points (top-left origin) — used when no label/identifier is given.",
    ]
    properties["y"] = [
      "type": "number",
      "description": "Y coordinate in device points (top-left origin).",
    ]
    properties["normalized"] = [
      "type": "boolean",
      "description": "When true, x/y are 0-1 fractions of the screen instead of points.",
    ]
    properties["holdSeconds"] = [
      "type": "number",
      "description": "Hold duration for a long-press. Defaults to a normal tap.",
    ]
    return [
      "name": "agenthub_simulator_tap",
      "description": "Taps the booted iOS Simulator — by element label/identifier (resolved through the accessibility tree; preferred) or by coordinates. Use it to drive the app to the screen you need to verify: call agenthub_simulator_describe_ui to see elements, tap your way there, then screenshot/describe to confirm. Injects HID events directly into the device (no host mouse, no permissions).",
      "inputSchema": [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
      ],
    ]
  }

  private func simulatorSwipeToolSchema() -> [String: Any] {
    var properties = simulatorDeviceProperties()
    properties["direction"] = [
      "type": "string",
      "enum": ["up", "down", "left", "right"],
      "description": "Centered swipe preset — the direction the FINGER moves (swipe up scrolls content down the page).",
    ]
    properties["fromX"] = ["type": "number", "description": "Start X in device points (or 0-1 with normalized)."]
    properties["fromY"] = ["type": "number", "description": "Start Y in device points."]
    properties["toX"] = ["type": "number", "description": "End X in device points."]
    properties["toY"] = ["type": "number", "description": "End Y in device points."]
    properties["normalized"] = [
      "type": "boolean",
      "description": "When true, from/to coordinates are 0-1 fractions of the screen.",
    ]
    properties["durationSeconds"] = [
      "type": "number",
      "description": "Gesture duration. Defaults to 0.3; use ~1.0 for slow drags.",
    ]
    return [
      "name": "agenthub_simulator_swipe",
      "description": "Swipes/drags on the booted iOS Simulator — pass a direction preset (up/down/left/right) to scroll, or explicit from/to coordinates for precise drags. Part of the drive-then-verify loop with agenthub_simulator_tap and agenthub_simulator_describe_ui.",
      "inputSchema": [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
      ],
    ]
  }

  private func simulatorTypeToolSchema() -> [String: Any] {
    var properties = simulatorDeviceProperties()
    properties["text"] = [
      "type": "string",
      "description": "Text to type into the focused field (tap the field first). US-layout characters only; \\n presses return.",
    ]
    properties["key"] = [
      "type": "string",
      "enum": ["return", "delete", "escape", "tab", "space", "up", "down", "left", "right"],
      "description": "A single named key to press instead of text (e.g. delete to clear characters).",
    ]
    properties["times"] = [
      "type": "integer",
      "description": "Repeat count for key. Defaults to 1.",
    ]
    return [
      "name": "agenthub_simulator_type",
      "description": "Types text (or presses a named key) into the booted iOS Simulator via HID keyboard events. Tap a text field first so it has focus, then type; verify with agenthub_simulator_describe_ui (the field's value reflects the input).",
      "inputSchema": [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
      ],
    ]
  }

  private func simulatorPressButtonToolSchema() -> [String: Any] {
    var properties = simulatorDeviceProperties()
    properties["button"] = [
      "type": "string",
      "enum": ["home", "swipeHome", "lock", "appSwitcher"],
      "description": "Hardware button/gesture. Use swipeHome for the home gesture on edge-to-edge (Face ID) devices when home has no effect.",
    ]
    return [
      "name": "agenthub_simulator_press_button",
      "description": "Presses a simulator hardware button: home, swipeHome (edge-to-edge home gesture), lock, or appSwitcher.",
      "inputSchema": [
        "type": "object",
        "properties": properties,
        "required": ["button"],
        "additionalProperties": false,
      ],
    ]
  }

  private func simulatorRecordToolSchema() -> [String: Any] {
    [
      "name": "agenthub_simulator_record",
      "description": "Starts or stops a simulator video recording for the same device shown in AgentHub's Simulator panel. After stop, finalized MP4s include ffprobe/ffmpeg hints for animation and motion timing audits.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "action": [
            "type": "string",
            "enum": ["start", "stop"],
            "description": "Recording action. Defaults to start.",
          ],
          "udid": [
            "type": "string",
            "description": "Optional simulator UDID. Defaults to the AgentHub Simulator panel target.",
          ],
          "sessionId": [
            "type": "string",
            "description": "Optional AgentHub session id. Defaults to AGENTHUB_SESSION_ID.",
          ],
          "projectPath": [
            "type": "string",
            "description": "Optional project path used only to resolve the panel context.",
          ],
          "repo": [
            "type": "string",
            "description": "Alias for projectPath.",
          ],
          "outputDirectory": [
            "type": "string",
            "description": "Optional directory for the MP4. Defaults to Application Support/AgentHub/Simulator Recordings.",
          ],
          "fileName": [
            "type": "string",
            "description": "Optional output filename. .mp4 is appended when omitted.",
          ],
        ],
        "additionalProperties": false,
      ],
    ]
  }

  private func writeResponse(id: Any, result: [String: Any]) {
    writeJSON([
      "jsonrpc": "2.0",
      "id": id,
      "result": result,
    ])
  }

  private func writeError(id: Any?, code: Int, message: String) {
    var response: [String: Any] = [
      "jsonrpc": "2.0",
      "error": [
        "code": code,
        "message": message,
      ],
    ]
    if let id {
      response["id"] = id
    }
    writeJSON(response)
  }

  private func writeJSON(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [])
    else {
      // Never silently drop a JSON-RPC message: a dropped response leaves the
      // caller's tool call loading forever. Surface it on stderr (stdout is
      // reserved for the protocol) so the failure is at least diagnosable.
      FileHandle.standardError.write(
        Data("agenthub mcp-server: failed to serialize a JSON-RPC message\n".utf8)
      )
      return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  private func requestId(from line: String) -> Any? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
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
      "worktrees": items.map(\.dictionary),
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
        "codex": sessionCounts.codex,
      ],
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
      "sidebarCleanupRequestId": sidebarCleanupRequestId,
    ]
  }
}

/// Outcome of a multi-task `agenthub_create_worktree_sessions` call. Successes
/// and failures are reported together so one failing task never aborts the
/// batch or leaves the caller's tool call hanging.
private struct MCPWorktreeBatchResult {
  var successes: [MCPWorktreeLaunchResult] = []
  var failures: [MCPWorktreeTaskFailure] = []
}

private struct MCPWorktreeTaskFailure {
  let branch: String
  let message: String

  var summary: String {
    "Failed to create worktree \(branch): \(message)"
  }

  var dictionary: [String: Any] {
    [
      "branch": branch,
      "error": message,
    ]
  }
}

private struct MCPWorktreeLaunchResult {
  let branch: String
  let provider: WorktreeLaunchProvider
  let repositoryPath: String
  let worktreePath: String
  let launchPath: String
  let isSparseCheckout: Bool
  let sparseCheckoutPaths: [String]
  let launchRequestId: String

  var summary: String {
    let cwdSuffix = launchPath == worktreePath ? "" : " launching in \(launchPath)"
    let checkoutKind = isSparseCheckout ? "sparse" : "full"
    return "Queued AgentHub \(provider.rawValue) session for \(branch) at \(worktreePath) (\(checkoutKind) checkout\(cwdSuffix), request \(launchRequestId))."
  }

  var dictionary: [String: Any] {
    [
      "branch": branch,
      "provider": provider.commandLineValue,
      "repositoryPath": repositoryPath,
      "worktreePath": worktreePath,
      "launchPath": launchPath,
      "isSparseCheckout": isSparseCheckout,
      "sparseCheckoutPaths": sparseCheckoutPaths,
      "launchRequestId": launchRequestId,
    ]
  }
}

private struct MCPSimulatorTarget {
  /// Nil means "the app resolves the project's persisted run destination".
  let udid: String?
  let projectPath: String?
  let context: SimulatorSessionContext?

  var displayName: String {
    context?.deviceName ?? udid ?? "the project's saved destination"
  }

  var dictionary: [String: Any] {
    var value: [String: Any] = [:]
    if let udid {
      value["udid"] = udid
    }
    if let projectPath {
      value["projectPath"] = projectPath
    }
    if let context {
      value["context"] = context.dictionary
    }
    return value
  }
}

private struct MCPSimulatorStatusResult {
  let activeContext: SimulatorSessionContext?
  let contexts: [SimulatorSessionContext]
  let bootedDevices: [SimctlDevice]

  var summary: String {
    var lines: [String] = []
    if let activeContext {
      let device = activeContext.deviceName ?? activeContext.udid
      let runtime = activeContext.runtimeName.map { " on \($0)" } ?? ""
      let bootState = liveBootState(for: activeContext) ? "booted" : "not booted"
      lines.append("AgentHub Simulator panel target: \(device)\(runtime) (\(activeContext.udid)), \(bootState), project \(activeContext.projectPath).")
    } else {
      lines.append("No active AgentHub Simulator panel context found. agenthub_simulator_run still works when a projectPath is passed — the app resolves the project's saved run destination.")
    }

    if bootedDevices.isEmpty {
      lines.append("No simulators are currently booted.")
    } else {
      let devices = bootedDevices
        .map { "\($0.name) (\($0.runtimeName), \($0.udid))" }
        .joined(separator: ", ")
      lines.append("Booted simulators: \(devices).")
    }
    return lines.joined(separator: "\n")
  }

  /// Contexts survive app crashes; simctl is the live truth for boot state.
  private func liveBootState(for context: SimulatorSessionContext) -> Bool {
    bootedDevices.contains { $0.udid == context.udid } || context.isBooted
  }

  var dictionary: [String: Any] {
    var value: [String: Any] = [
      "contexts": contexts.map(\.dictionary),
      "bootedSimulators": bootedDevices.map { device -> [String: Any] in
        [
          "udid": device.udid,
          "name": device.name,
          "runtime": device.runtimeName,
        ]
      },
      "recordingSupported": true,
      "runRequestSupported": true,
      "screenshotSupported": true,
      "describeUISupported": true,
      "uiInteractionSupported": true,
    ]
    if let activeContext {
      value["activeContext"] = activeContext.dictionary
    }
    return value
  }
}

private enum MCPSimulatorRunResult {
  /// Fire-and-forget (`waitSeconds: 0`) — queued, not yet finished.
  case queued(requestID: String, target: MCPSimulatorTarget)
  /// The wait elapsed with the request still in the queue (building, or the
  /// AgentHub app is not running to consume it).
  case stillRunning(requestID: String, target: MCPSimulatorTarget?, waitedSeconds: Int)
  /// Terminal outcome written by the app.
  case finished(SimulatorRunResult)
  /// The queue marked the request failed but no result detail was written
  /// (older AgentHub app version).
  case failedWithoutDetail(requestID: String, target: MCPSimulatorTarget?)
  case unknownRequest(requestID: String)

  var isError: Bool {
    switch self {
    case .queued, .stillRunning:
      return false
    case .finished(let result):
      return result.status == .failed
    case .failedWithoutDetail, .unknownRequest:
      return true
    }
  }

  var summary: String {
    switch self {
    case .queued(let requestID, let target):
      return "Queued AgentHub simulator Build & Run request \(requestID) for \(target.displayName). Call agenthub_simulator_run again with requestId \"\(requestID)\" to get the outcome."

    case .stillRunning(let requestID, _, let waitedSeconds):
      return [
        "Build & Run request \(requestID) is still in progress after \(waitedSeconds)s (large projects can take several minutes on a first build).",
        "Call agenthub_simulator_run again with requestId \"\(requestID)\" to keep waiting. If the AgentHub app is not running, the request stays queued until it launches.",
      ].joined(separator: "\n")

    case .finished(let result):
      switch result.status {
      case .succeeded:
        var lines = ["Build & Run succeeded for \(result.projectPath) on \(result.udid ?? "the project's saved destination")."]
        if result.hotReloadArmed {
          lines.append("Hot reload is armed: edits to existing Swift files now hot-swap into the running app automatically — no rebuild call needed for those. Structural changes (new/deleted files) rebuild automatically too.")
        }
        lines.append("Verify the change visually with agenthub_simulator_screenshot or structurally with agenthub_simulator_describe_ui.")
        return lines.joined(separator: "\n")
      case .failed:
        return [
          "Build & Run FAILED for \(result.projectPath)\(result.udid.map { " on \($0)" } ?? "").",
          result.errorMessage ?? "No error detail was captured.",
          "Fix the error and call agenthub_simulator_run again.",
        ].joined(separator: "\n")
      }

    case .failedWithoutDetail(let requestID, _):
      return "Build & Run request \(requestID) failed, but no error detail was recorded. Check the AgentHub Simulator panel for the build error."

    case .unknownRequest(let requestID):
      return "No simulator run with requestId \"\(requestID)\" was found — the id may be mistyped or its result already expired. Start a new run with agenthub_simulator_run."
    }
  }

  var dictionary: [String: Any] {
    switch self {
    case .queued(let requestID, let target):
      return [
        "requestId": requestID,
        "status": "queued",
        "target": target.dictionary,
      ]
    case .stillRunning(let requestID, let target, let waitedSeconds):
      var value: [String: Any] = [
        "requestId": requestID,
        "status": "running",
        "waitedSeconds": waitedSeconds,
      ]
      if let target {
        value["target"] = target.dictionary
      }
      return value
    case .finished(let result):
      var value: [String: Any] = [
        "requestId": result.requestId,
        "status": result.status.rawValue,
        "projectPath": result.projectPath,
        "hotReloadArmed": result.hotReloadArmed,
      ]
      if let udid = result.udid {
        value["udid"] = udid
      }
      if let errorMessage = result.errorMessage {
        value["error"] = errorMessage
      }
      return value
    case .failedWithoutDetail(let requestID, let target):
      var value: [String: Any] = [
        "requestId": requestID,
        "status": "failed",
      ]
      if let target {
        value["target"] = target.dictionary
      }
      return value
    case .unknownRequest(let requestID):
      return [
        "requestId": requestID,
        "status": "unknown",
      ]
    }
  }
}

private struct MCPSimulatorScreenshotResult {
  let target: MCPSimulatorTarget
  let outputPath: String

  var summary: String {
    [
      "Captured a screenshot of \(target.displayName)\(target.udid.map { " (\($0))" } ?? "").",
      "Saved PNG: \(outputPath)",
      "Read the file to inspect the current UI.",
    ].joined(separator: "\n")
  }

  var dictionary: [String: Any] {
    [
      "target": target.dictionary,
      "outputPath": outputPath,
    ]
  }
}

private struct MCPSimulatorInteractionResult {
  let action: String
  let target: MCPSimulatorTarget
  let detail: String

  var summary: String {
    [
      detail,
      "Verify the result with agenthub_simulator_describe_ui or agenthub_simulator_screenshot (allow ~0.5s for animations to settle).",
    ].joined(separator: "\n")
  }

  var dictionary: [String: Any] {
    [
      "action": action,
      "target": target.dictionary,
      "detail": detail,
    ]
  }
}

private struct MCPSimulatorDescribeUIResult {
  let target: MCPSimulatorTarget
  let elementCount: Int
  let treeText: String

  var summary: String {
    [
      "Accessibility tree of the frontmost app on \(target.displayName)\(target.udid.map { " (\($0))" } ?? "") — \(elementCount) elements (role \"label\" id=identifier value (x, y, wxh) in device points):",
      treeText,
    ].joined(separator: "\n")
  }

  var dictionary: [String: Any] {
    [
      "target": target.dictionary,
      "elementCount": elementCount,
      "tree": treeText,
    ]
  }
}

private enum MCPSimulatorRecordResult {
  case started(SimulatorRecordingStarted, target: MCPSimulatorTarget)
  case stopped(SimulatorRecordingResult, target: MCPSimulatorTarget)

  var isError: Bool {
    switch self {
    case .started:
      return false
    case let .stopped(result, _):
      return !result.isUsable
    }
  }

  var summary: String {
    switch self {
    case let .started(started, target):
      return "Started simulator recording for \(target.displayName) (\(started.udid)). Output: \(started.outputPath)"
    case let .stopped(result, target):
      if result.isUsable {
        return [
          "Stopped simulator recording for \(target.displayName) (\(result.udid)).",
          "Saved finalized MP4: \(result.outputPath)",
          "Duration: \(String(format: "%.1f", result.duration))s",
          "Use ffprobe or ffmpeg to inspect motion timing, for example: ffprobe -hide_banner \(shellExample(result.outputPath))",
        ].joined(separator: "\n")
      }

      return [
        "Stopped simulator recording for \(target.displayName) (\(result.udid)).",
        "Recording did not produce a finalized MP4: \(result.validationError ?? "validation failed")",
        "Output path: \(result.outputPath)",
      ].joined(separator: "\n")
    }
  }

  var dictionary: [String: Any] {
    switch self {
    case let .started(started, target):
      return [
        "action": "start",
        "target": target.dictionary,
        "recording": started.dictionary,
      ]
    case let .stopped(result, target):
      var value: [String: Any] = [
        "action": "stop",
        "target": target.dictionary,
        "recording": result.dictionary,
      ]
      if result.isUsable {
        value["ffmpegHints"] = [
          "ffprobe -hide_banner \(shellExample(result.outputPath))",
          "ffmpeg -i \(shellExample(result.outputPath)) -vf fps=6 frames/frame-%04d.png",
        ]
      }
      return value
    }
  }

  private func shellExample(_ path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

private extension SimulatorSessionContext {
  var dictionary: [String: Any] {
    var value: [String: Any] = [
      "projectPath": projectPath,
      "udid": udid,
      "isBooted": isBooted,
      "panelVisible": panelVisible,
      "updatedAt": iso8601(updatedAt),
    ]
    if let provider {
      value["provider"] = provider.commandLineValue
    }
    if let sessionId {
      value["sessionId"] = sessionId
    }
    if let deviceName {
      value["deviceName"] = deviceName
    }
    if let runtimeName {
      value["runtimeName"] = runtimeName
    }
    if let displayMode {
      value["displayMode"] = displayMode
    }
    return value
  }
}

private extension SimulatorRecordingStarted {
  var dictionary: [String: Any] {
    [
      "udid": udid,
      "outputPath": outputPath,
      "startedAt": iso8601(startedAt),
    ]
  }
}

private extension SimulatorRecordingResult {
  var dictionary: [String: Any] {
    var value: [String: Any] = [
      "udid": udid,
      "outputPath": outputPath,
      "startedAt": iso8601(startedAt),
      "endedAt": iso8601(endedAt),
      "duration": duration,
      "fileExists": fileExists,
      "isFinalized": isFinalized,
      "isUsable": isUsable,
    ]
    if let fileSizeBytes {
      value["fileSizeBytes"] = fileSizeBytes
    }
    if let validationError {
      value["validationError"] = validationError
    }
    return value
  }
}

private func iso8601(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}

private enum MCPError: LocalizedError {
  case invalidRequest(String)

  var errorDescription: String? {
    switch self {
    case let .invalidRequest(message):
      return message
    }
  }
}
