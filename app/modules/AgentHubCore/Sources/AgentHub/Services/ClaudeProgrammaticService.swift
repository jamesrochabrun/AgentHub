//
//  ClaudeProgrammaticService.swift
//  AgentHub
//
//  Shared infrastructure for one-shot `claude -p` (programmatic) invocations.
//  Used by features that need a short, non-interactive LLM call with a
//  model fallback chain, per-request timeout, and user cancellation.
//

import Combine
import ClaudeCodeClient
import Foundation

public struct ClaudeProgrammaticRequest: Sendable {
  public let systemPrompt: String
  public let userPrompt: String
  public let workingDirectory: String
  public let models: [String]
  public let timeout: Duration
  public let permissionMode: String?
  public let disallowedTools: [String]?
  public let logPrefix: String

  public init(
    systemPrompt: String,
    userPrompt: String,
    workingDirectory: String,
    models: [String],
    timeout: Duration,
    permissionMode: String? = nil,
    disallowedTools: [String]? = nil,
    logPrefix: String
  ) {
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
    self.workingDirectory = workingDirectory
    self.models = models
    self.timeout = timeout
    self.permissionMode = permissionMode
    self.disallowedTools = disallowedTools
    self.logPrefix = logPrefix
  }
}

public enum ClaudeProgrammaticError: Error, LocalizedError {
  case timeout(Duration)
  case allModelsRejected(lastMessage: String)
  case noOutput
  case completionFailure(underlying: Error, output: String)

  public var errorDescription: String? {
    switch self {
    case .timeout(let duration):
      return "Claude programmatic request timed out after \(Self.timeoutLabel(duration))"
    case .allModelsRejected(let message):
      return "All configured Claude models were rejected: \(message)"
    case .noOutput:
      return "Claude returned no output"
    case .completionFailure(let underlying, let output):
      if output.isEmpty {
        return underlying.localizedDescription
      }
      return "\(underlying.localizedDescription) | output: \(output)"
    }
  }

  public var output: String? {
    if case .completionFailure(_, let output) = self {
      return output.isEmpty ? nil : output
    }
    return nil
  }

  private static func timeoutLabel(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    return String(format: "%.1f seconds", seconds)
  }
}

public protocol ClaudeProgrammaticServiceProtocol: Sendable {
  func run(
    _ request: ClaudeProgrammaticRequest,
    onModelAttempt: (@Sendable (String) -> Void)?
  ) async throws -> String

  func cancelActiveRequest() async
}

public extension ClaudeProgrammaticServiceProtocol {
  func run(_ request: ClaudeProgrammaticRequest) async throws -> String {
    try await run(request, onModelAttempt: nil)
  }
}

public actor ClaudeProgrammaticService: ClaudeProgrammaticServiceProtocol {
  public static let haikuFallbackModels: [String] = [
    "haiku",
    "claude-haiku-4-5",
    "claude-3-haiku-20240307"
  ]

  public typealias ClientFactory = @Sendable (_ command: String, _ paths: [String]) -> any ClaudeCLIClientProtocol

  private let additionalPaths: [String]
  private let defaults: UserDefaults
  private let clientFactory: ClientFactory
  private let uuidProvider: @Sendable () -> UUID

  private var activeRequestID: UUID?
  private var activeClient: (any ClaudeCLIClientProtocol)?
  private var userCancelledRequestIDs: Set<UUID> = []
  private var timedOutRequestIDs: Set<UUID> = []
  private var capturedFailure: CapturedFailure?

  private struct CapturedFailure {
    let requestID: UUID
    let error: any Error
  }

  public init(
    additionalPaths: [String],
    defaults: UserDefaults = .standard,
    clientFactory: @escaping ClientFactory = { command, paths in
      ClaudeCLIClient(
        command: command,
        additionalPaths: paths,
        environmentOverridesProvider: { CLIEnvironmentOverrides.environment },
        debugLogger: { message in
          AppLogger.intelligence.error("[CLAUDEPROG] Claude CLI debug: \(message, privacy: .public)")
        }
      )
    },
    uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.additionalPaths = additionalPaths
    self.defaults = defaults
    self.clientFactory = clientFactory
    self.uuidProvider = uuidProvider
  }

  public func run(
    _ request: ClaudeProgrammaticRequest,
    onModelAttempt: (@Sendable (String) -> Void)? = nil
  ) async throws -> String {
    let requestID = uuidProvider()
    activeRequestID = requestID
    activeClient = nil

    let command = defaults.string(forKey: AgentHubDefaults.claudeCommand) ?? "claude"

    let raceOutcome = await withTaskGroup(of: RaceOutcome?.self, returning: RaceOutcome?.self) { group in
      group.addTask { [self] in
        do {
          let output = try await self.iterateModels(
            request: request,
            requestID: requestID,
            command: command,
            onModelAttempt: onModelAttempt
          )
          return .success(output)
        } catch is CancellationError {
          return .cancelled
        } catch {
          await self.captureFailure(requestID: requestID, error: error)
          return .failed
        }
      }

      group.addTask { [self] in
        do {
          try await Task.sleep(for: request.timeout)
          await self.markTimedOut(requestID: requestID)
          await self.cancelActiveClient()
          return .timedOut
        } catch {
          return nil
        }
      }

      while let next = await group.next() {
        guard let next else { continue }
        group.cancelAll()
        return next
      }

      return nil
    }

    switch raceOutcome {
    case .success(let output):
      clearActiveRequest(requestID)
      return output
    case .failed:
      let didTimeOut = timedOutRequestIDs.contains(requestID)
      let userCancelled = isUserCancelled(requestID)
      let capturedError = takeCapturedFailure(for: requestID)
      clearActiveRequest(requestID)
      if didTimeOut {
        AppLogger.intelligence.error(
          "\(request.logPrefix, privacy: .public) Claude programmatic request timed out after \(Self.timeoutLabel(request.timeout), privacy: .public); active CLI was cancelled"
        )
        throw ClaudeProgrammaticError.timeout(request.timeout)
      }
      if userCancelled {
        throw CancellationError()
      }
      throw capturedError ?? ClaudeProgrammaticError.noOutput
    case .cancelled:
      _ = takeCapturedFailure(for: requestID)
      clearActiveRequest(requestID)
      throw CancellationError()
    case .timedOut, .none:
      let userCancelled = isUserCancelled(requestID) || Task.isCancelled
      _ = takeCapturedFailure(for: requestID)
      clearActiveRequest(requestID)
      if userCancelled {
        throw CancellationError()
      }
      AppLogger.intelligence.error(
        "\(request.logPrefix, privacy: .public) Claude programmatic request timed out after \(Self.timeoutLabel(request.timeout), privacy: .public); active CLI was cancelled"
      )
      throw ClaudeProgrammaticError.timeout(request.timeout)
    }
  }

  public func cancelActiveRequest() async {
    guard let requestID = activeRequestID else { return }
    userCancelledRequestIDs.insert(requestID)
    AppLogger.intelligence.info(
      "[CLAUDEPROG] User requested cancellation requestID=\(requestID.uuidString, privacy: .public)"
    )
    await cancelActiveClient()
  }

  private func iterateModels(
    request: ClaudeProgrammaticRequest,
    requestID: UUID,
    command: String,
    onModelAttempt: (@Sendable (String) -> Void)?
  ) async throws -> String {
    var lastRejectionMessage = ""

    for (index, model) in request.models.enumerated() {
      onModelAttempt?(model)

      AppLogger.intelligence.info(
        "\(request.logPrefix, privacy: .public) Invoking Claude CLI command=\(command, privacy: .public) model=\(model, privacy: .public) cwd=\(request.workingDirectory, privacy: .public)"
      )

      let client = clientFactory(command, additionalPaths)
      setActiveClient(client, for: requestID)

      do {
        let output = try await collectOutput(
          using: client,
          request: request,
          model: model
        )
        setActiveClient(nil, for: requestID)
        if isUserCancelled(requestID) || Task.isCancelled {
          throw CancellationError()
        }
        AppLogger.intelligence.info(
          "\(request.logPrefix, privacy: .public) Claude returned output length=\(output.count) model=\(model, privacy: .public)"
        )
        return output
      } catch {
        setActiveClient(nil, for: requestID)
        if isUserCancelled(requestID) || Task.isCancelled {
          throw CancellationError()
        }
        if index < request.models.count - 1,
           let rejectionMessage = Self.modelSelectionRejectionMessage(from: error) {
          lastRejectionMessage = rejectionMessage
          AppLogger.intelligence.warning(
            "\(request.logPrefix, privacy: .public) Claude rejected model=\(model, privacy: .public); retrying with next model. Details: \(rejectionMessage, privacy: .public)"
          )
          continue
        }
        if let rejectionMessage = Self.modelSelectionRejectionMessage(from: error) {
          throw ClaudeProgrammaticError.allModelsRejected(lastMessage: rejectionMessage)
        }
        AppLogger.intelligence.error(
          "\(request.logPrefix, privacy: .public) Claude programmatic request failed model=\(model, privacy: .public) error=\(Self.describeError(error), privacy: .public)"
        )
        throw error
      }
    }

    if !lastRejectionMessage.isEmpty {
      throw ClaudeProgrammaticError.allModelsRejected(lastMessage: lastRejectionMessage)
    }
    throw ClaudeProgrammaticError.noOutput
  }

  private func collectOutput(
    using client: any ClaudeCLIClientProtocol,
    request: ClaudeProgrammaticRequest,
    model: String
  ) async throws -> String {
    let accumulator = StreamAccumulator()

    let publisher = client.runStreamingPrompt(
      prompt: request.userPrompt,
      workingDirectory: request.workingDirectory,
      systemPrompt: request.systemPrompt,
      permissionMode: request.permissionMode,
      disallowedTools: request.disallowedTools,
      model: model
    )

    let box = CancellableBox()
    return try await withCheckedThrowingContinuation { continuation in
      box.cancellable = publisher.sink(
        receiveCompletion: { completion in
          let output = accumulator.preferredOutput()
          box.cancellable = nil

          switch completion {
          case .finished:
            continuation.resume(returning: output)
          case .failure(let error):
            if !output.isEmpty {
              continuation.resume(throwing: ClaudeProgrammaticError.completionFailure(
                underlying: error,
                output: output
              ))
            } else {
              continuation.resume(throwing: error)
            }
          }
        },
        receiveValue: { chunk in
          accumulator.ingest(chunk)
        }
      )
    }
  }

  private func setActiveClient(_ client: (any ClaudeCLIClientProtocol)?, for requestID: UUID) {
    guard activeRequestID == requestID else { return }
    activeClient = client
  }

  private func cancelActiveClient() async {
    let client = activeClient
    activeClient = nil
    guard let client else { return }
    await MainActor.run {
      client.cancel()
    }
  }

  private func clearActiveRequest(_ requestID: UUID) {
    if activeRequestID == requestID {
      activeRequestID = nil
      activeClient = nil
    }
    userCancelledRequestIDs.remove(requestID)
    timedOutRequestIDs.remove(requestID)
  }

  private func isUserCancelled(_ requestID: UUID) -> Bool {
    userCancelledRequestIDs.contains(requestID)
  }

  private func markTimedOut(requestID: UUID) {
    timedOutRequestIDs.insert(requestID)
  }

  private enum RaceOutcome: Sendable {
    case success(String)
    case failed
    case timedOut
    case cancelled
  }

  private func captureFailure(requestID: UUID, error: any Error) {
    capturedFailure = CapturedFailure(requestID: requestID, error: error)
  }

  private func takeCapturedFailure(for requestID: UUID) -> (any Error)? {
    guard let captured = capturedFailure, captured.requestID == requestID else {
      return nil
    }
    capturedFailure = nil
    return captured.error
  }

  private static func timeoutLabel(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    return String(format: "%.1f seconds", seconds)
  }

  public static func modelSelectionRejectionMessage(from error: Error) -> String? {
    if let programmaticError = error as? ClaudeProgrammaticError,
       let output = programmaticError.output,
       (output.localizedCaseInsensitiveContains("issue with the selected model")
        || output.localizedCaseInsensitiveContains("may not exist or you may not have access")) {
      return output
    }

    if let clientError = error as? ClaudeCodeClientError,
       case .executionFailed(let message) = clientError,
       (message.localizedCaseInsensitiveContains("issue with the selected model")
        || message.localizedCaseInsensitiveContains("may not exist or you may not have access")) {
      return message
    }

    return nil
  }

  public static func describeError(_ error: Error) -> String {
    if let programmaticError = error as? ClaudeProgrammaticError {
      return programmaticError.errorDescription ?? String(describing: error)
    }
    if let clientError = error as? ClaudeCodeClientError,
       case .executionFailed(let message) = clientError {
      return message
    }
    return error.localizedDescription
  }

  public static func failureOutput(from error: Error) -> String? {
    if let programmaticError = error as? ClaudeProgrammaticError {
      let output = (programmaticError.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return output.isEmpty ? nil : output
    }
    if let clientError = error as? ClaudeCodeClientError,
       case .executionFailed(let message) = clientError {
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    let trimmed = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

// MARK: - Stream Accumulation

private final class StreamAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var latestAssistantText: String = ""
  private var finalResultText: String = ""

  func ingest(_ chunk: StreamJSONChunk) {
    lock.lock()
    defer { lock.unlock() }

    switch chunk {
    case .assistant(let message):
      let text = message.message.content.compactMap { content -> String? in
        guard case .text(let chunkText) = content else { return nil }
        return chunkText
      }.joined()

      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        latestAssistantText = text
      }

    case .result(let resultMessage):
      if let result = resultMessage.result?.trimmingCharacters(in: .whitespacesAndNewlines),
         !result.isEmpty {
        finalResultText = result
      }

    default:
      break
    }
  }

  func preferredOutput() -> String {
    lock.lock()
    defer { lock.unlock() }

    let preferred = finalResultText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !preferred.isEmpty {
      return preferred
    }
    return latestAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class CancellableBox: @unchecked Sendable {
  var cancellable: AnyCancellable?
}
