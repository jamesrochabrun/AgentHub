import AgentHubCLIKit
import Darwin
import Foundation

struct AgentHubMCPServer {
  private let service = WorktreeManagementService()
  private let queue = WorktreeLaunchRequestQueue()
  private let deletionQueue = WorktreeDeletionRequestQueue()
  private let sessionNameQueue = SessionNameRequestQueue()
  private let progressQueue = WorktreeProgressQueue()
  private let measurementQueue = MeasurementRecordQueue()
  private let measurementIndex = MeasurementIndexStore()

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
            nameSessionToolSchema(),
            recordMeasurementToolSchema(),
            listMeasurementsToolSchema(),
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
          writeResponse(id: id, result: toolResult(
            text: "AgentHub tool '\(timeout.toolName)' timed out after \(timeout.seconds) seconds and was aborted. Any worktrees already created remain on disk — call agenthub_list_worktrees to see them, then retry only the tasks that are still missing.",
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

    case "agenthub_name_session":
      return try nameSession(arguments: arguments)

    case "agenthub_record_measurement":
      return try recordMeasurement(arguments: arguments)

    case "agenthub_list_measurements":
      return listMeasurements(arguments: arguments)

    default:
      throw MCPError.invalidRequest("Unknown AgentHub tool: \(name).")
    }
  }

  /// Applies a session name in a single call.
  ///
  /// Deliberately one round trip: the calling agent already holds the
  /// conversation this session is about, so a "fetch context first" phase buys
  /// nothing and every extra hop is another place the model can stop short of
  /// actually renaming. `name` is required for the same reason — a tool that
  /// can be called with no arguments invites a call that renames nothing.
  private func nameSession(arguments: [String: Any]) throws -> [String: Any] {
    guard let provider = ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
    else {
      throw MCPError.invalidRequest(
        "agenthub_name_session is only available inside an AgentHub-managed Claude or Codex session."
      )
    }

    let name = try requiredString("name", in: arguments)
    guard let formattedName = SessionNameFormatter.format(name) else {
      throw MCPError.invalidRequest(
        "The session name must contain at least one letter or number."
      )
    }

    let request = SessionNameRequest(
      name: formattedName,
      sourceProvider: provider,
      sourceSessionId: ProcessInfo.processInfo.environment["AGENTHUB_SESSION_ID"],
      sourceProcessId: getppid()
    )
    try sessionNameQueue.enqueue(request)

    return toolResult(
      text: "AgentHub accepted the session name: \(formattedName). It appears in the session list momentarily.",
      structuredContent: [
        "queued": true,
        "name": formattedName,
        "provider": provider.commandLineValue,
      ]
    )
  }

  /// Files one measurement into the session's Measurements panel.
  ///
  /// Requires a chart or a table: the point of the panel is that a claim arrives
  /// with the numbers behind it, so a text-only "measurement" is rejected rather
  /// than rendered as an unfalsifiable assertion.
  private func recordMeasurement(arguments: [String: Any]) throws -> [String: Any] {
    guard let provider = ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
      .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
    else {
      throw MCPError.invalidRequest(
        "agenthub_record_measurement is only available inside an AgentHub-managed Claude or Codex session."
      )
    }

    let title = try requiredString("title", in: arguments)
    let claim = try requiredString("claim", in: arguments)
    let chart = try parseMeasurementChart(arguments["chart"])
    let table = try parseMeasurementTable(arguments["table"])

    guard chart != nil || table != nil else {
      throw MCPError.invalidRequest(
        "agenthub_record_measurement needs a chart or a table. A claim with no numbers behind it is an assertion, not a measurement — pass the aggregated result you derived the claim from."
      )
    }

    let caveats = Array(
      (try optionalStringArray("caveats", in: arguments) ?? [])
        .prefix(MeasurementRecord.Limits.maxCaveats)
    )

    // An explicit id means this is a re-run of a card that already exists: the
    // app upserts on id, so the existing card refreshes in place instead of a
    // near-duplicate piling up beneath it.
    let record = MeasurementRecord(
      id: optionalString("id", in: arguments).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
      title: title,
      claim: claim,
      question: optionalString("question", in: arguments),
      query: optionalString("query", in: arguments),
      source: optionalString("source", in: arguments),
      caveats: caveats,
      chart: chart,
      table: table,
      sourceProvider: provider,
      sourceSessionId: ProcessInfo.processInfo.environment["AGENTHUB_SESSION_ID"],
      sourceProjectPath: ProcessInfo.processInfo.environment["AGENTHUB_PROJECT_PATH"],
      sourceProcessId: getppid()
    )
    try measurementQueue.enqueue(record)

    return toolResult(
      text: "AgentHub recorded the measurement \"\(title)\". It appears in this session's Measurements panel momentarily.",
      structuredContent: [
        "queued": true,
        "id": record.id,
        "title": title,
        "hasChart": chart != nil,
        "hasTable": table != nil,
      ]
    )
  }

  /// Lists the measurements already tracked for this project.
  ///
  /// Without this, an agent asked to "refresh the build-time measurement" has no
  /// way to learn that measurement's id or its stored query, so it files a fresh
  /// card computed a slightly different way — the exact drift the panel exists
  /// to prevent.
  private func listMeasurements(arguments: [String: Any]) -> [String: Any] {
    let projectPath = optionalString("projectPath", in: arguments)
      ?? ProcessInfo.processInfo.environment["AGENTHUB_PROJECT_PATH"]
      ?? FileManager.default.currentDirectoryPath

    guard let index = measurementIndex.read(projectPath: projectPath) else {
      return toolResult(
        text: "No measurements recorded for this project yet.",
        structuredContent: ["projectPath": projectPath, "measurements": []]
      )
    }

    let entries = index.measurements.map { entry -> [String: Any] in
      var object: [String: Any] = [
        "id": entry.id,
        "title": entry.title,
        "latestClaim": entry.latestClaim,
        "lastRunAt": ISO8601DateFormatter().string(from: entry.lastRunAt),
        "runCount": entry.runCount,
      ]
      if let question = entry.question { object["question"] = question }
      if let query = entry.query { object["query"] = query }
      if let source = entry.source { object["source"] = source }
      return object
    }

    let summary = index.measurements.isEmpty
      ? "No measurements recorded for this project yet."
      : index.measurements
        .map { "• \($0.title) — \($0.latestClaim) (\($0.runCount) run(s), id \($0.id))" }
        .joined(separator: "\n")

    return toolResult(
      text: summary,
      structuredContent: ["projectPath": index.projectPath, "measurements": entries]
    )
  }

  private func parseMeasurementChart(_ raw: Any?) throws -> MeasurementChart? {
    guard let raw, !(raw is NSNull) else { return nil }
    guard let object = raw as? [String: Any] else {
      throw MCPError.invalidRequest("Expected chart to be an object.")
    }

    let rawKind = (object["kind"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? MeasurementChart.Kind.bar.rawValue
    guard let kind = MeasurementChart.Kind(rawValue: rawKind) else {
      let supported = MeasurementChart.Kind.allCases.map(\.rawValue).joined(separator: ", ")
      throw MCPError.invalidRequest("Unsupported chart kind '\(rawKind)'. Use one of: \(supported).")
    }

    guard let rawSeries = object["series"] as? [[String: Any]], !rawSeries.isEmpty else {
      throw MCPError.invalidRequest(
        "chart.series must be a non-empty array of { name, points } objects."
      )
    }
    guard rawSeries.count <= MeasurementRecord.Limits.maxSeries else {
      throw MCPError.invalidRequest(
        "chart.series has \(rawSeries.count) series but the limit is \(MeasurementRecord.Limits.maxSeries). Aggregate to fewer groups before charting."
      )
    }

    let series = try rawSeries.map { entry -> MeasurementSeries in
      guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
      else {
        throw MCPError.invalidRequest("Every chart series needs a non-empty name.")
      }
      guard let rawPoints = entry["points"] as? [[String: Any]], !rawPoints.isEmpty else {
        throw MCPError.invalidRequest("Series '\(name)' needs a non-empty points array.")
      }
      guard rawPoints.count <= MeasurementRecord.Limits.maxPointsPerSeries else {
        throw MCPError.invalidRequest(
          "Series '\(name)' has \(rawPoints.count) points but the limit is \(MeasurementRecord.Limits.maxPointsPerSeries). Bucket the data before charting."
        )
      }

      let points = try rawPoints.map { point -> MeasurementPoint in
        guard let x = measurementLabel(point["x"]), !x.isEmpty else {
          throw MCPError.invalidRequest("Every point in series '\(name)' needs an x label.")
        }
        guard let y = measurementNumber(point["y"]) else {
          throw MCPError.invalidRequest("Point '\(x)' in series '\(name)' needs a numeric y value.")
        }
        return MeasurementPoint(x: x, y: y)
      }
      return MeasurementSeries(name: name, points: points)
    }

    return MeasurementChart(
      kind: kind,
      xLabel: optionalString("xLabel", in: object),
      yLabel: optionalString("yLabel", in: object),
      series: series
    )
  }

  private func parseMeasurementTable(_ raw: Any?) throws -> MeasurementTable? {
    guard let raw, !(raw is NSNull) else { return nil }
    guard let object = raw as? [String: Any] else {
      throw MCPError.invalidRequest("Expected table to be an object.")
    }
    guard let columns = (object["columns"] as? [String])?
      .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
      !columns.isEmpty
    else {
      throw MCPError.invalidRequest("table.columns must be a non-empty array of strings.")
    }
    guard columns.count <= MeasurementRecord.Limits.maxTableColumns else {
      throw MCPError.invalidRequest(
        "table.columns has \(columns.count) columns but the limit is \(MeasurementRecord.Limits.maxTableColumns)."
      )
    }

    let rawRows = object["rows"] as? [[Any]] ?? []
    guard rawRows.count <= MeasurementRecord.Limits.maxTableRows else {
      throw MCPError.invalidRequest(
        "table.rows has \(rawRows.count) rows but the limit is \(MeasurementRecord.Limits.maxTableRows). Aggregate or take a top-N slice, and say which in caveats."
      )
    }

    let rows = try rawRows.map { row -> [String] in
      guard row.count == columns.count else {
        throw MCPError.invalidRequest(
          "Every table row must have \(columns.count) cells to match table.columns; found a row with \(row.count)."
        )
      }
      return row.map { measurementLabel($0) ?? "" }
    }

    return MeasurementTable(columns: columns, rows: rows)
  }

  /// Coerces a JSON scalar to a display label. Numbers arrive as `NSNumber`
  /// from `JSONSerialization`, and integral values must not render as "5.0".
  private func measurementLabel(_ raw: Any?) -> String? {
    switch raw {
    case let value as String:
      return value.trimmingCharacters(in: .whitespacesAndNewlines)
    case let value as NSNumber:
      let doubleValue = value.doubleValue
      if doubleValue == doubleValue.rounded(), abs(doubleValue) < 1e15 {
        return String(value.int64Value)
      }
      return String(doubleValue)
    default:
      return nil
    }
  }

  private func measurementNumber(_ raw: Any?) -> Double? {
    switch raw {
    case let value as NSNumber:
      return value.doubleValue
    case let value as String:
      return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
      return nil
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

  private func nameSessionToolSchema() -> [String: Any] {
    [
      "name": "agenthub_name_session",
      "description": """
        Renames the current session in AgentHub's session list. Call this whenever the user asks \
        to name, rename, retitle, or suggest a name for this session — including bare requests \
        like "name this session", "rename the session", or "give this session a better name". \
        Base the name on what this session has already been working on: do not read files, run \
        git, or re-scan the conversation first. If the user did not state a name, propose 3 short \
        candidates in your reply, then call this once with the one they pick. Renaming only \
        happens through this call, so never say the session was renamed without calling it.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "name": [
            "type": "string",
            "minLength": 1,
            "description": "Short kebab-case name for this session, ideally 2-4 words (for example, fix-session-naming). AgentHub normalizes it to lowercase kebab-case.",
          ],
        ],
        "required": ["name"],
        "additionalProperties": false,
      ],
    ]
  }

  private func recordMeasurementToolSchema() -> [String: Any] {
    [
      "name": "agenthub_record_measurement",
      "description": """
        Files a measurement into this session's Measurements panel in AgentHub, where it renders as a \
        chart or table with the query behind it. Call this whenever you finish an analysis that \
        produces numbers the user will make a decision on — querying a database, aggregating a \
        CSV or log file, counting events, comparing cohorts, sizing an opportunity — including \
        when the user did not explicitly ask you to record anything. One call per distinct \
        measurement; do not batch unrelated results into one card. Write `claim` the way you would \
        say it out loud to a product review: the conclusion and its size, not a description of \
        what you did. Always pass `query` when a query or script produced the numbers, so the \
        claim can be checked rather than trusted. Use `caveats` for anything that would change \
        how the number should be read — partial time windows, excluded rows, small samples, \
        top-N truncation, a metric you defined yourself rather than one that already existed. \
        Prefer a chart; add a table only when exact values matter. Do not call this for code \
        changes, file edits, or work that produced no measurement. Before filing a new measurement, \
        call agenthub_list_measurements: if one already measures this, run its stored query instead \
        of writing a fresh one and pass its id here, so the card updates and its history builds \
        up rather than a near-duplicate appearing next to it.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "id": [
            "type": "string",
            "description": "Only when re-running an existing measurement: pass that measurement's id so its card refreshes in place. Omit for a new measurement.",
          ],
          "title": [
            "type": "string",
            "minLength": 1,
            "description": "Short headline for the card, e.g. 'Week-2 retention by signup channel'.",
          ],
          "claim": [
            "type": "string",
            "minLength": 1,
            "description": "The measurement in plain English, stated as a conclusion with its magnitude. Example: 'Referral signups retain at 41% in week 2 versus 22% for paid — roughly double, on 3.1k users.'",
          ],
          "question": [
            "type": "string",
            "description": "The question this analysis set out to answer, if there was an explicit one.",
          ],
          "query": [
            "type": "string",
            "description": "The SQL, script, or command that produced these numbers. Shown collapsed under the chart.",
          ],
          "source": [
            "type": "string",
            "description": "Where the data came from — table name, file path, or endpoint.",
          ],
          "caveats": [
            "type": "array",
            "items": ["type": "string"],
            "description": "Limitations that change how the number should be read (partial windows, excluded segments, small samples, self-defined metrics).",
          ],
          "chart": [
            "type": "object",
            "description": "The data to plot. AgentHub draws the chart — send values, never HTML or image markup.",
            "properties": [
              "kind": [
                "type": "string",
                "enum": MeasurementChart.Kind.allCases.map(\.rawValue),
                "description": "bar for comparisons across categories, line/area for a value over time, point for correlation.",
              ],
              "xLabel": ["type": "string", "description": "Label for the x axis."],
              "yLabel": ["type": "string", "description": "Label for the y axis."],
              "series": [
                "type": "array",
                "minItems": 1,
                "maxItems": MeasurementRecord.Limits.maxSeries,
                "description": "One entry per plotted group. Use several series to compare segments on the same axes.",
                "items": [
                  "type": "object",
                  "properties": [
                    "name": ["type": "string", "description": "Series name, shown in the legend."],
                    "points": [
                      "type": "array",
                      "minItems": 1,
                      "maxItems": MeasurementRecord.Limits.maxPointsPerSeries,
                      "items": [
                        "type": "object",
                        "properties": [
                          "x": ["type": "string", "description": "Category, bucket, or date label. Send points already sorted."],
                          "y": ["type": "number", "description": "The measured value."],
                        ],
                        "required": ["x", "y"],
                      ],
                    ],
                  ],
                  "required": ["name", "points"],
                ],
              ],
            ],
            "required": ["kind", "series"],
          ],
          "table": [
            "type": "object",
            "description": "Optional exact values, aggregated or top-N — not a raw row dump.",
            "properties": [
              "columns": [
                "type": "array",
                "items": ["type": "string"],
                "maxItems": MeasurementRecord.Limits.maxTableColumns,
              ],
              "rows": [
                "type": "array",
                "maxItems": MeasurementRecord.Limits.maxTableRows,
                "items": ["type": "array", "description": "One cell per column, in column order."],
              ],
            ],
            "required": ["columns", "rows"],
          ],
        ],
        "required": ["title", "claim"],
        "additionalProperties": false,
      ],
    ]
  }

  private func listMeasurementsToolSchema() -> [String: Any] {
    [
      "name": "agenthub_list_measurements",
      "description": """
        Lists the measurements already recorded for this project in AgentHub, with each one's id, \
        title, latest claim, and the query that produced it. Call this before recording a new \
        measurement, so an existing measurement gets refreshed instead of a near-duplicate card \
        appearing beside it. Also call it whenever the user asks to re-run, refresh, or update \
        a measurement, or asks what is already being tracked or measured: match their words against \
        the titles, run that measurement's stored query exactly as written, then call \
        agenthub_record_measurement with its id. Measurements are shared across every session in the \
        project, Claude and Codex alike, so this will list work done in conversations other \
        than this one.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "projectPath": [
            "type": "string",
            "description": "Project to list measurements for. Defaults to the current AgentHub session's project, which is almost always what you want.",
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

private enum MCPError: LocalizedError {
  case invalidRequest(String)

  var errorDescription: String? {
    switch self {
    case let .invalidRequest(message):
      return message
    }
  }
}
