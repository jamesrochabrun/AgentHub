//
//  LocalDiffSummaryService.swift
//  AgentHubGitDiff
//
//  Summarizes local/branch changes for compact UI entry points.
//

import Foundation

public struct LocalDiffSummary: Equatable, Sendable {
  public let fileCount: Int
  public let additions: Int
  public let deletions: Int

  public static let empty = LocalDiffSummary(fileCount: 0, additions: 0, deletions: 0)

  public init(fileCount: Int, additions: Int, deletions: Int) {
    self.fileCount = fileCount
    self.additions = additions
    self.deletions = deletions
  }
}

public protocol LocalDiffSummaryServiceProtocol: Sendable {
  func cachedSummary(for projectPath: String) async -> LocalDiffSummary?
  func summary(for projectPath: String) async -> LocalDiffSummary
  func invalidate(projectPath: String) async
}

public actor LocalDiffSummaryService: LocalDiffSummaryServiceProtocol {
  public static let shared = LocalDiffSummaryService()

  typealias Evaluator = @Sendable (String) async -> LocalDiffSummary

  private struct InFlightEvaluation: Sendable {
    let id: UUID
    let generation: Int
    let task: Task<LocalDiffSummary, Never>
  }

  private let evaluator: Evaluator
  private let minimumRefreshInterval: TimeInterval
  private let adaptiveThrottleMultiplier: Double
  private var cache: [String: LocalDiffSummary] = [:]
  private var cacheGeneration: [String: Int] = [:]
  private var inFlightTasks: [String: InFlightEvaluation] = [:]
  private var lastEvaluationStartedAt: [String: Date] = [:]
  private var lastEvaluationDuration: [String: TimeInterval] = [:]

  init(
    evaluator: Evaluator? = nil,
    minimumRefreshInterval: TimeInterval = 1.0,
    adaptiveThrottleMultiplier: Double = 3.0
  ) {
    self.evaluator = evaluator ?? { projectPath in
      await Self.defaultEvaluator(projectPath: projectPath)
    }
    self.minimumRefreshInterval = minimumRefreshInterval
    self.adaptiveThrottleMultiplier = adaptiveThrottleMultiplier
  }

  public func cachedSummary(for projectPath: String) async -> LocalDiffSummary? {
    cache[Self.normalize(projectPath)]
  }

  public func summary(for projectPath: String) async -> LocalDiffSummary {
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
    let evaluationStartedAt = Date.now
    lastEvaluationStartedAt[normalizedProjectPath] = evaluationStartedAt
    let inFlightEvaluation = InFlightEvaluation(
      id: UUID(),
      generation: cacheGeneration[normalizedProjectPath] ?? 0,
      task: task
    )
    inFlightTasks[normalizedProjectPath] = inFlightEvaluation

    let summary = await task.value
    if inFlightTasks[normalizedProjectPath]?.id == inFlightEvaluation.id {
      inFlightTasks.removeValue(forKey: normalizedProjectPath)
      lastEvaluationDuration[normalizedProjectPath] = Date.now.timeIntervalSince(evaluationStartedAt)
      if (cacheGeneration[normalizedProjectPath] ?? 0) == inFlightEvaluation.generation {
        cache[normalizedProjectPath] = summary
      }
    }
    return summary
  }

  public func invalidate(projectPath: String) async {
    let normalizedProjectPath = Self.normalize(projectPath)

    if inFlightTasks[normalizedProjectPath] != nil {
      return
    }

    if let lastEvaluationStartedAt = lastEvaluationStartedAt[normalizedProjectPath],
       Date.now.timeIntervalSince(lastEvaluationStartedAt) < effectiveRefreshInterval(for: normalizedProjectPath) {
      return
    }

    cacheGeneration[normalizedProjectPath, default: 0] += 1
    cache.removeValue(forKey: normalizedProjectPath)
  }

  /// Slow repos self-throttle: a worktree whose evaluation costs N seconds may
  /// only re-evaluate every `multiplier × N` seconds, so activity-driven
  /// invalidations can't queue back-to-back full-worktree scans. Fast repos
  /// stay on the minimum floor and keep live summaries.
  private func effectiveRefreshInterval(for normalizedProjectPath: String) -> TimeInterval {
    guard let duration = lastEvaluationDuration[normalizedProjectPath] else {
      return minimumRefreshInterval
    }
    return max(minimumRefreshInterval, adaptiveThrottleMultiplier * duration)
  }

  public nonisolated static func normalize(_ projectPath: String) -> String {
    URL(fileURLWithPath: projectPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  private nonisolated static func defaultEvaluator(projectPath: String) async -> LocalDiffSummary {
    await Task.detached(priority: .utility) {
      let service = GitDiffService()
      var filesByPath: [String: GitDiffFileEntry] = [:]

      for mode in DiffMode.allCases {
        do {
          let state = try await service.changedFiles(at: projectPath, mode: mode, baseBranch: nil)
          for file in state.files where filesByPath[file.relativePath] == nil {
            filesByPath[file.relativePath] = file
          }
        } catch {
          continue
        }
      }

      let additions = filesByPath.values.reduce(0) { $0 + $1.additions }
      let deletions = filesByPath.values.reduce(0) { $0 + $1.deletions }
      return LocalDiffSummary(
        fileCount: filesByPath.count,
        additions: additions,
        deletions: deletions
      )
    }.value
  }
}
