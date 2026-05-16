import AgentHubCLIKit
import ArgumentParser
import Foundation

@main
struct AgentHubCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agenthub",
    abstract: "AgentHub command-line helper.",
    subcommands: [
      WorktreeCommand.self,
    ]
  )
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

  func run() async throws {
    let service = WorktreeManagementService()
    let directoryName = WorktreeNaming.worktreeDirectoryName(for: branch)
    let path = try await service.createWorktreeWithNewBranch(
      at: options.repositoryPath,
      newBranchName: branch,
      directoryName: directoryName,
      startPoint: from
    )
    try printResult(path: path, branch: branch, json: options.json)
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

  func run() async throws {
    let service = WorktreeManagementService()
    let directoryName = WorktreeNaming.worktreeDirectoryName(for: branch)
    let resolvedPath = try await service.checkoutWorktree(
      at: options.repositoryPath,
      branch: branch,
      directoryName: directoryName
    )

    try printResult(path: resolvedPath, branch: branch, json: options.json)
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

private func printResult(path: String, branch: String, json: Bool) throws {
  if json {
    try JSONPrinter.print(WorktreePathResult(path: path, branch: branch))
  } else {
    Swift.print(path)
  }
}
