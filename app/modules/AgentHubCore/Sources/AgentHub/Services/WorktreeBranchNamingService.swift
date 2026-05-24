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
  ) async throws -> WorktreeBranchNamingResult
  func cancelActiveRequest() async
}

public extension WorktreeBranchNamingServiceProtocol {
  func resolveBranchNames(for request: WorktreeBranchNamingRequest) async throws -> WorktreeBranchNamingResult {
    try await resolveBranchNames(for: request, onProgress: nil)
  }
}

public actor ClaudeWorktreeBranchNamingService: WorktreeBranchNamingServiceProtocol {
  private static let logPrefix = "[AIWORKTREE]"
  private static let namingTimeout: Duration = .seconds(15)
  static let namingModels = ClaudeProgrammaticService.haikuFallbackModels

  private let defaults: UserDefaults
  private let programmaticService: any ClaudeProgrammaticServiceProtocol
  private let namingTimeoutDuration: Duration
  private let uuidProvider: @Sendable () -> UUID

  /// Convenience init that wires up a default `ClaudeProgrammaticService`.
  /// Preserves the legacy parameter shape consumed by tests.
  init(
    additionalPaths: [String],
    defaults: UserDefaults = .standard,
    clientFactory: @escaping ClaudeProgrammaticService.ClientFactory = { command, paths in
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
    self.init(
      programmaticService: ClaudeProgrammaticService(
        additionalPaths: additionalPaths,
        defaults: defaults,
        clientFactory: clientFactory,
        uuidProvider: uuidProvider
      ),
      defaults: defaults,
      namingTimeout: namingTimeout ?? Self.namingTimeout,
      uuidProvider: uuidProvider
    )
  }

  /// Primary init used when the surrounding app already has a shared
  /// `ClaudeProgrammaticService` (e.g. from `AgentHubProvider`).
  public init(
    programmaticService: any ClaudeProgrammaticServiceProtocol,
    defaults: UserDefaults = .standard,
    namingTimeout: Duration? = nil,
    uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.programmaticService = programmaticService
    self.defaults = defaults
    self.namingTimeoutDuration = namingTimeout ?? Self.namingTimeout
    self.uuidProvider = uuidProvider
  }

  public func resolveBranchNames(
    for request: WorktreeBranchNamingRequest,
    onProgress: (@MainActor @Sendable (WorktreeBranchNamingProgress) -> Void)? = nil
  ) async throws -> WorktreeBranchNamingResult {
    let settings = WorktreeBranchNamingSettings.load(from: defaults)
    let providers = request.providerKinds.map(\.rawValue).joined(separator: ",")
    let attachments = request.attachmentBasenames.joined(separator: ",")
    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Naming request context=\(request.launchContext.rawValue, privacy: .public) repo=\(request.repoName, privacy: .public) base=\(request.baseBranchName ?? "HEAD", privacy: .public) providers=\(providers, privacy: .public) promptLength=\(request.promptText.count) attachments=\(attachments, privacy: .public)"
    )
    if !request.hasMeaningfulContext {
      AppLogger.intelligence.info(
        "\(Self.logPrefix, privacy: .public) No prompt or attachment context provided; requesting random city name from AI"
      )
    }
    await emitProgress(
      .preparingContext(message: "Preparing branch name"),
      using: onProgress
    )

    let systemPrompt = makeSystemPrompt(hasContext: request.hasMeaningfulContext)
    let userPrompt = makeUserPrompt(for: request)

    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Claude naming system prompt:\n\(systemPrompt, privacy: .public)"
    )
    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Claude naming user prompt:\n\(userPrompt, privacy: .public)"
    )

    let programmaticRequest = ClaudeProgrammaticRequest(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      workingDirectory: request.repoPath,
      models: Self.namingModels,
      timeout: namingTimeoutDuration,
      permissionMode: nil,
      disallowedTools: nil,
      logPrefix: Self.logPrefix
    )

    let progressForwarder: (@Sendable (String) -> Void)? = onProgress.map { callback in
      { model in
        Task { @MainActor in
          callback(.queryingModel(model: model, message: "Generating branch name"))
        }
      }
    }

    let candidate: String
    do {
      candidate = try await programmaticService.run(programmaticRequest, onModelAttempt: progressForwarder)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ClaudeProgrammaticError {
      if case .timeout = error {
        AppLogger.intelligence.error(
          "\(Self.logPrefix, privacy: .public) Branch naming timed out after \(Self.timeoutLabel(self.namingTimeoutDuration), privacy: .public); canceling Claude CLI and using deterministic fallback"
        )
        let fallback = Self.deterministicFallback(for: request, settings: settings, uuid: uuidProvider())
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
      return await fallbackFromGenericFailure(
        request: request,
        settings: settings,
        error: error,
        onProgress: onProgress
      )
    } catch {
      return await fallbackFromGenericFailure(
        request: request,
        settings: settings,
        error: error,
        onProgress: onProgress
      )
    }

    if Task.isCancelled {
      throw CancellationError()
    }

    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Claude returned branch stem candidate length=\(candidate.count)"
    )
    await emitProgress(.sanitizing(message: "Finalizing branch name"), using: onProgress)

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
  }

  public func cancelActiveRequest() async {
    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) User requested branch naming cancellation"
    )
    await programmaticService.cancelActiveRequest()
  }
}

extension ClaudeWorktreeBranchNamingService {
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

  func fallbackFromGenericFailure(
    request: WorktreeBranchNamingRequest,
    settings: WorktreeBranchNamingSettings,
    error: Error,
    onProgress: (@MainActor @Sendable (WorktreeBranchNamingProgress) -> Void)?
  ) async -> WorktreeBranchNamingResult {
    if let output = ClaudeProgrammaticService.failureOutput(from: error), !output.isEmpty {
      AppLogger.intelligence.error(
        "\(Self.logPrefix, privacy: .public) Claude naming failed stream-json output: \(output, privacy: .public)"
      )
    }
    AppLogger.intelligence.error(
      "\(Self.logPrefix, privacy: .public) Claude naming failed; using deterministic fallback: \(error.localizedDescription, privacy: .public)"
    )
    AppLogger.intelligence.error(
      "\(Self.logPrefix, privacy: .public) Claude naming failure details: \(ClaudeProgrammaticService.describeError(error), privacy: .public)"
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

  func makeSystemPrompt(hasContext: Bool) -> String {
    if hasContext {
      return """
      You generate git branch stems for developer tooling.

      Return exactly one branch stem and nothing else.

      Rules:
      - lowercase ascii only
      - use 2 to 5 hyphen-separated words when possible
      - no slash
      - no prefix such as feature/ or fix/
      - no uuid, timestamp, or explanation
      - no markdown, quotes, bullets, or prose
      """
    } else {
      return """
      You generate git branch stems for developer tooling.

      Return the name of a random city anywhere in the world, formatted as a branch stem.

      Rules:
      - lowercase ascii only
      - use hyphens to separate words if the city name has multiple words
      - no slash, no prefix, no uuid, no timestamp, no explanation
      - no markdown, quotes, bullets, or prose
      - just the city name, nothing else
      - pick a different city each time, be creative and varied across all continents
      """
    }
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

  func logResolvedNames(_ result: WorktreeBranchNamingResult) {
    AppLogger.intelligence.info(
      "\(Self.logPrefix, privacy: .public) Resolved branch names source=\(result.source.rawValue, privacy: .public) single=\(result.single ?? "-", privacy: .public) claude=\(result.claude ?? "-", privacy: .public) codex=\(result.codex ?? "-", privacy: .public)"
    )
  }
}
