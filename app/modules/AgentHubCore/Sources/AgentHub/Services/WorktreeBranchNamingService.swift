//
//  WorktreeBranchNamingService.swift
//  AgentHub
//

import Combine
import ClaudeCodeClient
import Foundation

public protocol WorktreeBranchNamingServiceProtocol: Sendable {
  func resolveBranchNames(
    for request: WorktreeBranchNamingRequest,
    onProgress: (@MainActor @Sendable (WorktreeBranchNamingProgress) -> Void)?
  ) async -> WorktreeBranchNamingResult
}

public extension WorktreeBranchNamingServiceProtocol {
  func resolveBranchNames(for request: WorktreeBranchNamingRequest) async -> WorktreeBranchNamingResult {
    await resolveBranchNames(for: request, onProgress: nil)
  }
}

public actor ClaudeWorktreeBranchNamingService: WorktreeBranchNamingServiceProtocol {
  private static let logPrefix = "[AIWORKTREE]"
  private static let namingTimeout: Duration = .seconds(15)
  private static let namingModels = [
    "haiku",
    "claude-haiku-4-5",
    "claude-3-haiku-20240307"
  ]
  typealias ClientFactory = @Sendable (String, [String]) -> any ClaudeCLIClientProtocol

  private let additionalPaths: [String]
  private let defaults: UserDefaults
  private let clientFactory: ClientFactory
  private let namingTimeoutDuration: Duration
  private let uuidProvider: @Sendable () -> UUID

  init(
    additionalPaths: [String],
    defaults: UserDefaults = .standard,
    clientFactory: @escaping ClientFactory = { command, paths in
      ClaudeCLIClient(
        command: command,
        additionalPaths: paths,
        debugLogger: { message in
          AppLogger.intelligence.error("[AIWORKTREE] Claude CLI debug: \(message, privacy: .public)")
        }
      )
    },
    namingTimeout: Duration? = nil,
    uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.additionalPaths = additionalPaths
    self.defaults = defaults
    self.clientFactory = clientFactory
    self.namingTimeoutDuration = namingTimeout ?? Self.namingTimeout
    self.uuidProvider = uuidProvider
  }

  public func resolveBranchNames(
    for request: WorktreeBranchNamingRequest,
    onProgress: (@MainActor @Sendable (WorktreeBranchNamingProgress) -> Void)? = nil
  ) async -> WorktreeBranchNamingResult {
    let settings = WorktreeBranchNamingSettings.load(from: defaults)
    let providers = request.providerKinds.map(\.rawValue).joined(separator: ",")
    let attachments = request.attachmentBasenames.joined(separator: ",")
    let activeClientBox = ActiveClientBox()
    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Naming request context=\(request.launchContext.rawValue, privacy: .public) repo=\(request.repoName, privacy: .public) base=\(request.baseBranchName ?? "HEAD", privacy: .public) providers=\(providers, privacy: .public) promptLength=\(request.promptText.count) attachments=\(attachments, privacy: .public)"
    )
    if !request.hasMeaningfulContext {
      AppLogger.intelligence.info(
        "\(Self.logPrefix, privacy: .public) No prompt or attachment context provided; asking Claude to infer a repo-scoped branch stem from repository metadata"
      )
    }
    await emitProgress(
      .preparingContext(
        message: request.hasMeaningfulContext
          ? "Preparing branch naming context"
          : "Preparing repository context"
      ),
      using: onProgress
    )

    let command = defaults.string(forKey: AgentHubDefaults.claudeCommand) ?? "claude"
    let raceOutcome = await withTaskGroup(of: NamingRaceOutcome?.self, returning: NamingRaceOutcome?.self) { group in
      group.addTask { [self] in
        do {
          let result = try await resolveBranchNamesWithoutTimeout(
            for: request,
            settings: settings,
            command: command,
            activeClientBox: activeClientBox,
            onProgress: onProgress
          )
          return .resolved(result)
        } catch is CancellationError {
          return nil
        } catch {
          let fallback = Self.deterministicFallback(for: request, settings: settings, uuid: uuidProvider())
          await emitProgress(
            .completed(
              message: "Fallback branch name ready",
              source: fallback.source,
              branchNames: Self.resolvedBranchNames(from: fallback)
            ),
            using: onProgress
          )
          await self.logResolvedNames(fallback)
          return .resolved(fallback)
        }
      }

      group.addTask { [self] in
        do {
          try await Task.sleep(for: namingTimeoutDuration)
          await activeClientBox.cancel()
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
    case .resolved(let result):
      return result
    case .timedOut, .none:
      let fallback = Self.deterministicFallback(for: request, settings: settings, uuid: uuidProvider())
      AppLogger.intelligence.error(
        "\(Self.logPrefix, privacy: .public) Branch naming timed out after \(Self.timeoutLabel(self.namingTimeoutDuration), privacy: .public); canceling Claude CLI and using deterministic fallback"
      )
      await emitProgress(
        .completed(
          message: "Branch naming reached the 15-second limit, so AgentHub used a fallback name",
          source: fallback.source,
          branchNames: Self.resolvedBranchNames(from: fallback)
        ),
        using: onProgress
      )
      logResolvedNames(fallback)
      return fallback
    }
  }
}

extension ClaudeWorktreeBranchNamingService {
  actor ActiveClientBox {
    private var client: (any ClaudeCLIClientProtocol)?

    func set(_ client: (any ClaudeCLIClientProtocol)?) {
      self.client = client
    }

    func cancel() async {
      let client = self.client
      self.client = nil
      guard let client else { return }
      await MainActor.run {
        client.cancel()
      }
    }
  }

  enum NamingRaceOutcome {
    case resolved(WorktreeBranchNamingResult)
    case timedOut
  }

  func resolveBranchNamesWithoutTimeout(
    for request: WorktreeBranchNamingRequest,
    settings: WorktreeBranchNamingSettings,
    command: String,
    activeClientBox: ActiveClientBox,
    onProgress: (@MainActor @Sendable (WorktreeBranchNamingProgress) -> Void)?
  ) async throws -> WorktreeBranchNamingResult {
    for (index, model) in Self.namingModels.enumerated() {
      await emitProgress(
        .queryingModel(
          model: model,
          message: request.hasMeaningfulContext
            ? "Generating branch name"
            : "Generating a repository-scoped branch name"
        ),
        using: onProgress
      )
      AppLogger.intelligence.info(
        "\(Self.logPrefix, privacy: .public) Invoking Claude prompt naming with command=\(command, privacy: .public) model=\(model, privacy: .public) cwd=\(request.repoPath, privacy: .public)"
      )
      let client = clientFactory(command, additionalPaths)
      await activeClientBox.set(client)

      do {
        let candidate = try await collectCandidateStem(
          using: client,
          request: request,
          model: model
        )
        await activeClientBox.set(nil)
        try Task.checkCancellation()
        AppLogger.intelligence.info(
          "\(Self.logPrefix, privacy: .public) Claude returned branch stem candidate length=\(candidate.count)"
        )
        await emitProgress(
          .sanitizing(message: "Finalizing branch name"),
          using: onProgress
        )
        let sanitizedStem = Self.sanitizeGeneratedStem(candidate)
        guard !sanitizedStem.isEmpty else {
          AppLogger.intelligence.info(
            "\(Self.logPrefix, privacy: .public) Claude output sanitized to an empty stem; using deterministic fallback"
          )
          let fallback = Self.deterministicFallback(for: request, settings: settings, uuid: uuidProvider())
          await emitProgress(
            .completed(
              message: "Branch naming returned an unusable stem, so AgentHub used a fallback name",
              source: fallback.source,
              branchNames: Self.resolvedBranchNames(from: fallback)
            ),
            using: onProgress
          )
          logResolvedNames(fallback)
          return fallback
        }

        AppLogger.intelligence.info(
          "\(Self.logPrefix, privacy: .public) Sanitized AI stem=\(sanitizedStem, privacy: .public) prefix=\(settings.normalizedPrefix, privacy: .public)"
        )

        let result = Self.buildResult(
          stem: sanitizedStem,
          source: .ai,
          request: request,
          settings: settings,
          uuid: uuidProvider()
        )
        await emitProgress(
          .completed(
            message: "Branch name ready",
            source: result.source,
            branchNames: Self.resolvedBranchNames(from: result)
          ),
          using: onProgress
        )
        logResolvedNames(result)
        return result
      } catch {
        await activeClientBox.set(nil)
        try Task.checkCancellation()
        if index < Self.namingModels.count - 1,
           let rejectionMessage = Self.modelSelectionRejectionMessage(from: error) {
          AppLogger.intelligence.warning(
            "\(Self.logPrefix, privacy: .public) Claude rejected model=\(model, privacy: .public); retrying with fallback Haiku model. Details: \(rejectionMessage, privacy: .public)"
          )
          AppLogger.intelligence.warning(
            "\(Self.logPrefix, privacy: .public) Claude model rejection surfaced via stream-json output for model=\(model, privacy: .public): \(rejectionMessage, privacy: .public)"
          )
          continue
        }

        if let output = Self.failureOutput(from: error), !output.isEmpty {
          AppLogger.intelligence.error(
            "\(Self.logPrefix, privacy: .public) Claude naming failed stream-json output for model=\(model, privacy: .public): \(output, privacy: .public)"
          )
        }
        AppLogger.intelligence.error(
          "\(Self.logPrefix, privacy: .public) Claude naming failed; using deterministic fallback: \(error.localizedDescription, privacy: .public)"
        )
        AppLogger.intelligence.error(
          "\(Self.logPrefix, privacy: .public) Claude naming failure details for model=\(model, privacy: .public): \(Self.describeError(error), privacy: .public)"
        )
        let fallback = Self.deterministicFallback(for: request, settings: settings, uuid: uuidProvider())
        await emitProgress(
          .completed(
            message: "Branch naming was unavailable, so AgentHub used a fallback name",
            source: fallback.source,
            branchNames: Self.resolvedBranchNames(from: fallback)
          ),
          using: onProgress
        )
        logResolvedNames(fallback)
        return fallback
      }
    }

    let fallback = Self.deterministicFallback(for: request, settings: settings, uuid: uuidProvider())
    await emitProgress(
      .completed(
        message: "Fallback branch name ready",
        source: fallback.source,
        branchNames: Self.resolvedBranchNames(from: fallback)
      ),
      using: onProgress
    )
    logResolvedNames(fallback)
    return fallback
  }

  nonisolated static func deterministicFallback(
    for request: WorktreeBranchNamingRequest,
    settings: WorktreeBranchNamingSettings = .load(),
    uuid: UUID = UUID()
  ) -> WorktreeBranchNamingResult {
    buildResult(
      stem: deterministicStem(for: request),
      source: .deterministicFallback,
      request: request,
      settings: settings,
      uuid: uuid
    )
  }

  nonisolated static func sanitizeGeneratedStem(_ rawValue: String) -> String {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "" }

    if value.hasPrefix("```") {
      value = value
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let firstLine = value
      .components(separatedBy: .newlines)
      .first?
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` \t"))
      ?? ""

    let latin = firstLine
      .applyingTransform(.toLatin, reverse: false)?
      .applyingTransform(.stripCombiningMarks, reverse: false)
      ?? firstLine

    let normalized = latin.lowercased().map { character -> Character in
      if character.isASCII, (character.isLetter || character.isNumber) {
        return character
      }
      if character == " " || character == "_" || character == "-" {
        return "-"
      }
      return "-"
    }

    let collapsed = String(normalized)
      .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-."))

    return String(collapsed.prefix(48))
  }
}

private extension ClaudeWorktreeBranchNamingService {
  func emitProgress(
    _ progress: WorktreeBranchNamingProgress,
    using callback: (@MainActor @Sendable (WorktreeBranchNamingProgress) -> Void)?
  ) async {
    guard let callback else { return }
    await callback(progress)
  }

  enum NamingPromptFailure: LocalizedError {
    case completionFailure(underlying: Error, output: String)

    var errorDescription: String? {
      switch self {
      case .completionFailure(let underlying, let output):
        if output.isEmpty {
          return underlying.localizedDescription
        }
        return "\(underlying.localizedDescription) | output: \(output)"
      }
    }

    var output: String {
      switch self {
      case .completionFailure(_, let output):
        return output
      }
    }
  }

  final class StreamAccumulator: @unchecked Sendable {
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

  final class CancellableBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
  }

  func collectCandidateStem(
    using client: any ClaudeCLIClientProtocol,
    request: WorktreeBranchNamingRequest,
    model: String
  ) async throws -> String {
    let accumulator = StreamAccumulator()
    let systemPrompt = makeSystemPrompt()
    let userPrompt = makeUserPrompt(for: request)

    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Claude naming system prompt for model=\(model, privacy: .public):\n\(systemPrompt, privacy: .public)"
    )
    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Claude naming user prompt for model=\(model, privacy: .public):\n\(userPrompt, privacy: .public)"
    )

    let publisher = client.runStreamingPrompt(
      prompt: userPrompt,
      workingDirectory: request.repoPath,
      systemPrompt: systemPrompt,
      permissionMode: nil,
      disallowedTools: nil,
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
              continuation.resume(throwing: NamingPromptFailure.completionFailure(
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

  func makeSystemPrompt() -> String {
    """
    You generate git branch stems for developer tooling.

    Return exactly one branch stem and nothing else.

    Rules:
    - lowercase ascii only
    - use 2 to 5 hyphen-separated words when possible
    - no slash
    - no prefix such as feature/ or fix/
    - no uuid, timestamp, or explanation
    - no markdown, quotes, bullets, or prose
    - when prompt and attachments are empty, infer a useful repo-scoped stem from repository name, base branch, and launch context
    - avoid generic outputs like session or worktree when repository context is available
    """
  }

  func makeUserPrompt(for request: WorktreeBranchNamingRequest) -> String {
    let baseBranch = request.baseBranchName ?? "HEAD"
    let attachments = request.attachmentBasenames.isEmpty
      ? "none"
      : request.attachmentBasenames.joined(separator: ", ")
    let prompt = request.promptText.isEmpty ? "none" : request.promptText

    return """
    Repository: \(request.repoName)
    Launch context: \(request.launchContext.rawValue)
    Base branch: \(baseBranch)
    Providers: \(request.providerKinds.map(\.rawValue).joined(separator: ", "))
    Prompt: \(prompt)
    Attachments: \(attachments)
    """
  }

  nonisolated static func deterministicStem(for request: WorktreeBranchNamingRequest) -> String {
    let seedText: String
    if !request.promptText.isEmpty {
      seedText = request.promptText
    } else {
      seedText = request.attachmentBasenames.joined(separator: " ")
    }

    let words = seedText
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .prefix(4)
      .joined(separator: "-")

    let sanitized = sanitizeGeneratedStem(words)
    if !sanitized.isEmpty {
      return sanitized
    }

    let repoStem = sanitizeGeneratedStem(request.repoName)
    if !repoStem.isEmpty {
      switch request.launchContext {
      case .manualWorktree:
        return "\(repoStem)-session"
      case .smartFallback:
        return "\(repoStem)-smart"
      }
    }

    switch request.launchContext {
    case .manualWorktree:
      return "session"
    case .smartFallback:
      return "smart"
    }
  }

  nonisolated static func modelSelectionRejectionMessage(from error: Error) -> String? {
    if let namingFailure = error as? NamingPromptFailure {
      let output = namingFailure.output
      if output.localizedCaseInsensitiveContains("issue with the selected model")
        || output.localizedCaseInsensitiveContains("may not exist or you may not have access") {
        return output
      }
    }

    if let clientError = error as? ClaudeCodeClientError,
       case .executionFailed(let message) = clientError,
       (message.localizedCaseInsensitiveContains("issue with the selected model")
        || message.localizedCaseInsensitiveContains("may not exist or you may not have access")) {
      return message
    }

    return nil
  }

  nonisolated static func describeError(_ error: Error) -> String {
    if let namingFailure = error as? NamingPromptFailure {
      return namingFailure.errorDescription ?? String(describing: error)
    }

    if let clientError = error as? ClaudeCodeClientError,
       case .executionFailed(let message) = clientError {
      return message
    }

    return error.localizedDescription
  }

  nonisolated static func failureOutput(from error: Error) -> String? {
    if let namingFailure = error as? NamingPromptFailure {
      let output = namingFailure.output.trimmingCharacters(in: .whitespacesAndNewlines)
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

  nonisolated static func buildResult(
    stem: String,
    source: WorktreeBranchNameSource,
    request: WorktreeBranchNamingRequest,
    settings: WorktreeBranchNamingSettings,
    uuid: UUID
  ) -> WorktreeBranchNamingResult {
    let token = String(uuid.uuidString.prefix(6)).lowercased()
    let baseName = settings.normalizedPrefix + stem + "-" + token
    let providers = request.providerKinds.reduce(into: [SessionProviderKind]()) { partialResult, provider in
      if !partialResult.contains(provider) {
        partialResult.append(provider)
      }
    }

    guard providers.count > 1 else {
      return WorktreeBranchNamingResult(single: baseName, source: source)
    }

    return WorktreeBranchNamingResult(
      claude: providers.contains(.claude) ? baseName + "-claude" : nil,
      codex: providers.contains(.codex) ? baseName + "-codex" : nil,
      source: source
    )
  }

  nonisolated static func resolvedBranchNames(from result: WorktreeBranchNamingResult) -> [String] {
    [result.single, result.claude, result.codex].compactMap { $0 }
  }

  nonisolated static func timeoutLabel(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    return String(format: "%.1f seconds", seconds)
  }

  private func logResolvedNames(_ result: WorktreeBranchNamingResult) {
    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Resolved branch names source=\(result.source.rawValue, privacy: .public) single=\(result.single ?? "-", privacy: .public) claude=\(result.claude ?? "-", privacy: .public) codex=\(result.codex ?? "-", privacy: .public)"
    )
  }
}
