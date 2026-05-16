//
//  DiffAvailabilityService.swift
//  AgentHub
//

import Foundation

public enum DiffAvailabilityStatus: Equatable, Sendable {
  case checking
  case available
  case unavailable

  public var isAvailable: Bool {
    self == .available
  }

  public var isChecking: Bool {
    self == .checking
  }
}

public protocol DiffAvailabilityServiceProtocol: Sendable {
  func cachedAvailability(for projectPath: String) async -> DiffAvailabilityStatus?
  func availability(for projectPath: String) async -> DiffAvailabilityStatus
  func invalidate(projectPath: String) async
}

public actor DiffAvailabilityService: DiffAvailabilityServiceProtocol {
  public static let shared = DiffAvailabilityService()

  typealias Evaluator = @Sendable (String) async -> DiffAvailabilityStatus

  private struct InFlightEvaluation: Sendable {
    let id: UUID
    let generation: Int
    let task: Task<DiffAvailabilityStatus, Never>
  }

  private let evaluator: Evaluator
  private let minimumRefreshInterval: TimeInterval
  private var cache: [String: DiffAvailabilityStatus] = [:]
  private var cacheGeneration: [String: Int] = [:]
  private var inFlightTasks: [String: InFlightEvaluation] = [:]
  private var lastEvaluationStartedAt: [String: Date] = [:]

  init(
    evaluator: Evaluator? = nil,
    minimumRefreshInterval: TimeInterval = 1.0
  ) {
    self.evaluator = evaluator ?? { projectPath in
      await Self.defaultEvaluator(projectPath: projectPath)
    }
    self.minimumRefreshInterval = minimumRefreshInterval
  }

  public func cachedAvailability(for projectPath: String) async -> DiffAvailabilityStatus? {
    cache[Self.normalize(projectPath)]
  }

  public func availability(for projectPath: String) async -> DiffAvailabilityStatus {
    let normalizedProjectPath = Self.normalize(projectPath)

    if let cached = cache[normalizedProjectPath] {
      return cached
    }
    if let inFlightTask = inFlightTasks[normalizedProjectPath] {
      return await inFlightTask.task.value
    }

    let evaluator = evaluator
    let task = Task(priority: .utility) {
      await evaluator(normalizedProjectPath)
    }
    lastEvaluationStartedAt[normalizedProjectPath] = Date.now
    let inFlightEvaluation = InFlightEvaluation(
      id: UUID(),
      generation: cacheGeneration[normalizedProjectPath] ?? 0,
      task: task
    )
    inFlightTasks[normalizedProjectPath] = inFlightEvaluation

    let status = await task.value
    if inFlightTasks[normalizedProjectPath]?.id == inFlightEvaluation.id {
      inFlightTasks.removeValue(forKey: normalizedProjectPath)
      if (cacheGeneration[normalizedProjectPath] ?? 0) == inFlightEvaluation.generation {
        cache[normalizedProjectPath] = status
      }
    }
    return status
  }

  public func invalidate(projectPath: String) async {
    let normalizedProjectPath = Self.normalize(projectPath)

    if inFlightTasks[normalizedProjectPath] != nil {
      return
    }

    if let lastEvaluationStartedAt = lastEvaluationStartedAt[normalizedProjectPath],
       Date.now.timeIntervalSince(lastEvaluationStartedAt) < minimumRefreshInterval {
      return
    }

    cacheGeneration[normalizedProjectPath, default: 0] += 1
    cache.removeValue(forKey: normalizedProjectPath)
  }

  public nonisolated static func normalize(_ projectPath: String) -> String {
    URL(fileURLWithPath: projectPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  private nonisolated static func defaultEvaluator(projectPath: String) async -> DiffAvailabilityStatus {
    await Task.detached(priority: .utility) {
      evaluateGitDiffAvailability(projectPath: projectPath)
    }.value
  }

  private nonisolated static func evaluateGitDiffAvailability(projectPath: String) -> DiffAvailabilityStatus {
    let gitRootResult = runGit(["rev-parse", "--show-toplevel"], at: projectPath)
    guard gitRootResult.exitCode == 0 else {
      return .unavailable
    }

    let gitRoot = gitRootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !gitRoot.isEmpty else {
      return .unavailable
    }

    let unstagedDiff = runGit(["diff", "--quiet"], at: gitRoot)
    if unstagedDiff.exitCode == 1 {
      return .available
    }

    let stagedDiff = runGit(["diff", "--cached", "--quiet"], at: gitRoot)
    if stagedDiff.exitCode == 1 {
      return .available
    }

    let untrackedFiles = runGit(["ls-files", "--others", "--exclude-standard", "--directory"], at: gitRoot)
    if untrackedFiles.exitCode == 0, !untrackedFiles.output.isEmpty {
      return .available
    }

    guard let baseBranch = detectBaseBranch(at: gitRoot) else {
      return .unavailable
    }

    let branchDiff = runGit(["diff", "--quiet", "\(baseBranch)...HEAD"], at: gitRoot)
    switch branchDiff.exitCode {
    case 0:
      return .unavailable
    case 1:
      return .available
    default:
      return .unavailable
    }
  }

  private nonisolated static func detectBaseBranch(at gitRoot: String) -> String? {
    let candidates = [
      "refs/heads/main",
      "refs/heads/master",
      "refs/remotes/origin/main",
      "refs/remotes/origin/master",
    ]

    for candidate in candidates {
      let result = runGit(["rev-parse", "--verify", candidate], at: gitRoot)
      if result.exitCode == 0 {
        return candidate
      }
    }

    return nil
  }

  private struct GitCommandResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
  }

  private nonisolated static func runGit(
    _ arguments: [String],
    at path: String
  ) -> GitCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    process.environment = environment

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      try inputPipe.fileHandleForWriting.close()
    } catch {
      return GitCommandResult(
        output: "",
        errorOutput: error.localizedDescription,
        exitCode: 127
      )
    }

    var outputData: Data?
    var errorData: Data?
    let readGroup = DispatchGroup()

    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      outputData = try? outputPipe.fileHandleForReading.readToEnd()
      readGroup.leave()
    }

    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      errorData = try? errorPipe.fileHandleForReading.readToEnd()
      readGroup.leave()
    }

    process.waitUntilExit()
    readGroup.wait()

    return GitCommandResult(
      output: String(data: outputData ?? Data(), encoding: .utf8) ?? "",
      errorOutput: String(data: errorData ?? Data(), encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
  }
}
