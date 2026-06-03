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

  public var canShowDiffViewer: Bool {
    switch self {
    case .checking, .available:
      return true
    case .unavailable:
      return false
    }
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
      await evaluateGitDiffAvailability(projectPath: projectPath)
    }.value
  }

  private nonisolated static func evaluateGitDiffAvailability(projectPath: String) async -> DiffAvailabilityStatus {
    if (try? LibGit2DiffBackend.findGitRoot(at: projectPath)) != nil {
      return .available
    }

    if (try? await GitDiffService().findGitRoot(at: projectPath)) != nil {
      return .available
    }

    return .unavailable
  }
}
