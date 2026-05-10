//
//  ProjectCapabilityService.swift
//  AgentHub
//

import Foundation

public struct ProjectCapabilities: Equatable, Sendable {
  public let hasStorybook: Bool
  public let isXcodeProject: Bool

  public init(hasStorybook: Bool, isXcodeProject: Bool) {
    self.hasStorybook = hasStorybook
    self.isXcodeProject = isXcodeProject
  }
}

public protocol ProjectCapabilityServiceProtocol: Sendable {
  func cachedCapabilities(for projectPath: String) async -> ProjectCapabilities?
  func capabilities(for projectPath: String) async -> ProjectCapabilities
  func invalidate(projectPath: String) async
}

public actor ProjectCapabilityService: ProjectCapabilityServiceProtocol {
  public static let shared = ProjectCapabilityService()

  public typealias Evaluator = @Sendable (String) async -> ProjectCapabilities

  private struct InFlightEvaluation: Sendable {
    let id: UUID
    let generation: Int
    let task: Task<ProjectCapabilities, Never>
  }

  private let evaluator: Evaluator
  private var cache: [String: ProjectCapabilities] = [:]
  private var cacheGeneration: [String: Int] = [:]
  private var inFlightTasks: [String: InFlightEvaluation] = [:]

  public init(evaluator: Evaluator? = nil) {
    self.evaluator = evaluator ?? { projectPath in
      await Self.defaultEvaluator(projectPath: projectPath)
    }
  }

  public func cachedCapabilities(for projectPath: String) async -> ProjectCapabilities? {
    cache[Self.normalize(projectPath)]
  }

  public func capabilities(for projectPath: String) async -> ProjectCapabilities {
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
    let inFlightEvaluation = InFlightEvaluation(
      id: UUID(),
      generation: cacheGeneration[normalizedProjectPath] ?? 0,
      task: task
    )
    inFlightTasks[normalizedProjectPath] = inFlightEvaluation

    let capabilities = await task.value
    if inFlightTasks[normalizedProjectPath]?.id == inFlightEvaluation.id {
      inFlightTasks.removeValue(forKey: normalizedProjectPath)
      if (cacheGeneration[normalizedProjectPath] ?? 0) == inFlightEvaluation.generation {
        cache[normalizedProjectPath] = capabilities
      }
    }
    return capabilities
  }

  public func invalidate(projectPath: String) async {
    let normalizedProjectPath = Self.normalize(projectPath)
    cacheGeneration[normalizedProjectPath, default: 0] += 1
    cache.removeValue(forKey: normalizedProjectPath)
    inFlightTasks[normalizedProjectPath]?.task.cancel()
    inFlightTasks.removeValue(forKey: normalizedProjectPath)
  }

  private nonisolated static func defaultEvaluator(projectPath: String) async -> ProjectCapabilities {
    await Task.detached(priority: .utility) {
      ProjectCapabilities(
        hasStorybook: ProjectFramework.hasStorybook(at: projectPath),
        isXcodeProject: XcodeProjectDetector.isXcodeProject(at: projectPath)
      )
    }.value
  }

  public nonisolated static func normalize(_ projectPath: String) -> String {
    URL(fileURLWithPath: projectPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }
}
