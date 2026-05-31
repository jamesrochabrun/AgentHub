import AgentHubCLIKit
import ArgumentParser
import Foundation

@main
struct AgentHubCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agenthub",
    abstract: "AgentHub command-line helper.",
    subcommands: [
      AgentHubMCPServerCommand.self,
      WorktreeCommand.self,
      PlanCommand.self,
    ]
  )
}

struct PlanCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan",
    abstract: "Break a bundled prompt into subtasks and delegate them to the best-suited installed agent."
  )

  @Argument(help: "The bundled, multi-part prompt to plan and delegate.")
  var prompt: String

  @Option(name: .long, help: "Repository path for context. Defaults to AGENTHUB_PROJECT_PATH.")
  var repo: String?

  @Flag(name: .long, help: "Print machine-readable JSON.")
  var json = false

  func run() async throws {
    let repositoryPath = repo ?? ProcessInfo.processInfo.environment["AGENTHUB_PROJECT_PATH"]
    let plan = await AgentHubPlanningService().buildPlan(
      prompt: prompt,
      providedSubtasks: [],
      repositoryPath: repositoryPath
    )

    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(plan)
      Swift.print(String(decoding: data, as: UTF8.self))
      return
    }

    Swift.print("Delegation plan: \(plan.assignments.count) subtask(s)")
    for assignment in plan.assignments {
      let agent = assignment.assignedModel ?? "unassigned"
      Swift.print("\n[\(assignment.subtask.id)] \(assignment.subtask.title)")
      Swift.print("  agent:  \(agent)")
      Swift.print("  branch: \(assignment.branchSuggestion)")
      Swift.print("  why:    \(assignment.rationale)")
    }
    if !plan.notes.isEmpty {
      Swift.print("\nNotes:")
      for note in plan.notes {
        Swift.print("  • \(note)")
      }
    }
  }
}

struct AgentHubMCPServerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp-server",
    abstract: "Run the AgentHub MCP server over stdio."
  )

  func run() async throws {
    try await AgentHubMCPServer().run()
  }
}

struct WorktreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worktree",
    abstract: "Manage AgentHub git worktrees.",
    subcommands: [
      ListWorktrees.self,
      CreateWorktree.self,
      CheckoutWorktree.self,
      DeleteWorktree.self,
      PrintWorktreeRoot.self,
    ]
  )
}

struct WorktreeOptions: ParsableArguments {
  @Option(name: .long, help: "Repository path. Defaults to the current directory.")
  var repo: String?

  @Flag(name: .long, help: "Print machine-readable JSON.")
  var json = false

  var repositoryPath: String {
    repo ?? FileManager.default.currentDirectoryPath
  }
}

struct ListWorktrees: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List worktrees for a repository."
  )

  @OptionGroup var options: WorktreeOptions

  func run() async throws {
    let service = WorktreeManagementService()
    let worktrees = try await service.listWorktrees(at: options.repositoryPath)
    if options.json {
      try JSONPrinter.print(worktrees)
    } else {
      for worktree in worktrees {
        let branch = worktree.branch.map { " [\($0)]" } ?? ""
        Swift.print("\(worktree.path)\(branch)")
      }
    }
  }
}

struct CreateWorktree: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a new branch and worktree."
  )

  @Argument(help: "New branch name.")
  var branch: String

  @Option(name: .long, help: "Start point for the new branch.")
  var from: String?

  @OptionGroup var options: WorktreeOptions

  @Flag(name: .long, help: "Request AgentHub to launch an embedded session in the worktree.")
  var launchSession = false

  @Option(name: .long, help: "Provider for the launched session: claude or codex. Defaults to AGENTHUB_PROVIDER.")
  var provider: String?

  @Option(name: .long, help: "Prompt for the launched session. Required with --launch-session.")
  var prompt: String?

  func run() async throws {
    let service = WorktreeManagementService()
    let directoryName = WorktreeNaming.worktreeDirectoryName(for: branch)
    let path = try await service.createWorktreeWithNewBranch(
      at: options.repositoryPath,
      newBranchName: branch,
      directoryName: directoryName,
      startPoint: from
    )
    let launchRequestId = try await queueLaunchIfRequested(
      launchSession: launchSession,
      provider: provider,
      prompt: prompt,
      service: service,
      repositoryPath: options.repositoryPath,
      worktreePath: path,
      branch: branch
    )
    try printResult(path: path, branch: branch, launchRequestId: launchRequestId, json: options.json)
  }
}

struct CheckoutWorktree: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "checkout",
    abstract: "Create or reuse a worktree for an existing branch."
  )

  @Argument(help: "Existing branch name.")
  var branch: String

  @OptionGroup var options: WorktreeOptions

  @Flag(name: .long, help: "Request AgentHub to launch an embedded session in the worktree.")
  var launchSession = false

  @Option(name: .long, help: "Provider for the launched session: claude or codex. Defaults to AGENTHUB_PROVIDER.")
  var provider: String?

  @Option(name: .long, help: "Prompt for the launched session. Required with --launch-session.")
  var prompt: String?

  func run() async throws {
    let service = WorktreeManagementService()
    let directoryName = WorktreeNaming.worktreeDirectoryName(for: branch)
    let resolvedPath = try await service.checkoutWorktree(
      at: options.repositoryPath,
      branch: branch,
      directoryName: directoryName
    )

    let launchRequestId = try await queueLaunchIfRequested(
      launchSession: launchSession,
      provider: provider,
      prompt: prompt,
      service: service,
      repositoryPath: options.repositoryPath,
      worktreePath: resolvedPath,
      branch: branch
    )
    try printResult(path: resolvedPath, branch: branch, launchRequestId: launchRequestId, json: options.json)
  }
}

struct DeleteWorktree: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete",
    abstract: "Remove a worktree and delete its associated branch."
  )

  @Argument(help: "Branch name or worktree path.")
  var branchOrPath: String

  @Flag(name: .long, help: "Force removal and branch deletion.")
  var force = false

  @OptionGroup var options: WorktreeOptions

  func run() async throws {
    let service = WorktreeManagementService()
    try await service.removeWorktreeForBranchOrPath(
      branchOrPath,
      repoPath: options.repositoryPath,
      force: force
    )

    if options.json {
      try JSONPrinter.print(DeleteResult(target: branchOrPath, force: force))
    } else {
      Swift.print("Deleted \(branchOrPath)")
    }
  }
}

struct PrintWorktreeRoot: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "root",
    abstract: "Print the main worktree root for a repository."
  )

  @OptionGroup var options: WorktreeOptions

  func run() async throws {
    let service = WorktreeManagementService()
    let root = try await service.findMainRepositoryRoot(at: options.repositoryPath)
    if options.json {
      try JSONPrinter.print(RootResult(path: root))
    } else {
      Swift.print(root)
    }
  }
}

private struct WorktreePathResult: Codable {
  let path: String
  let branch: String
  let launchRequestId: String?
}

private struct DeleteResult: Codable {
  let target: String
  let force: Bool
}

private struct RootResult: Codable {
  let path: String
}

private enum JSONPrinter {
  static func print<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
      return
    }
    Swift.print(output)
  }
}

private func printResult(path: String, branch: String, launchRequestId: String? = nil, json: Bool) throws {
  if json {
    try JSONPrinter.print(WorktreePathResult(path: path, branch: branch, launchRequestId: launchRequestId))
  } else {
    Swift.print(path)
  }
}

private func queueLaunchIfRequested(
  launchSession: Bool,
  provider providerOption: String?,
  prompt promptOption: String?,
  service: WorktreeManagementService,
  repositoryPath: String,
  worktreePath: String,
  branch: String
) async throws -> String? {
  guard launchSession else { return nil }

  let launchProvider = try resolveLaunchProvider(providerOption)
  let prompt = try resolveLaunchPrompt(promptOption)
  let sourceProvider = ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
    .flatMap(WorktreeLaunchProvider.init(commandLineValue:))
  let sourceSessionId = ProcessInfo.processInfo.environment["AGENTHUB_SESSION_ID"]
  let mainRepositoryPath = try await service.findMainRepositoryRoot(at: repositoryPath)
  let request = WorktreeLaunchRequest(
    provider: launchProvider,
    repositoryPath: mainRepositoryPath,
    worktreePath: worktreePath,
    branchName: branch,
    prompt: prompt,
    sourceProvider: sourceProvider,
    sourceSessionId: sourceSessionId
  )

  let queued = try WorktreeLaunchRequestQueue().enqueue(request)
  return queued.request.id
}

private func resolveLaunchProvider(_ providerOption: String?) throws -> WorktreeLaunchProvider {
  let explicitProvider = providerOption.flatMap(WorktreeLaunchProvider.init(commandLineValue:))
  if let explicitProvider {
    return explicitProvider
  }

  if let providerOption, !providerOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw ValidationError("Invalid provider '\(providerOption)'. Expected claude or codex.")
  }

  if let environmentProvider = ProcessInfo.processInfo.environment["AGENTHUB_PROVIDER"]
    .flatMap(WorktreeLaunchProvider.init(commandLineValue:)) {
    return environmentProvider
  }

  throw ValidationError(WorktreeLaunchRequestQueueError.missingProvider.localizedDescription)
}

private func resolveLaunchPrompt(_ promptOption: String?) throws -> String {
  let prompt = promptOption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !prompt.isEmpty else {
    throw ValidationError(WorktreeLaunchRequestQueueError.missingPrompt.localizedDescription)
  }
  return prompt
}
