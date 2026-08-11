import Foundation

@MainActor
public protocol VoiceSessionManaging: AnyObject {
  var providerKind: SessionProviderKind { get }
  var voiceSessions: [CLISession] { get }
  var selectedRepositories: [SelectedRepository] { get }
  var sessionCustomNames: [String: String] { get }
  var monitorStates: [String: SessionMonitorState] { get }
  var sessionStatuses: [String: SessionStatus] { get }
  var pendingHubSessions: [PendingHubSession] { get }
  var resolvedPendingSessions: [UUID: String] { get }
  var lastCreatedPendingId: UUID? { get }

  func sendPromptToActiveTerminal(forKey key: String, prompt: String) -> Bool
  func showTerminalWithPrompt(for session: CLISession, prompt: String)
  func focusTerminal(forKey key: String)
  func voiceStartNewSessionInHub(
    _ worktree: WorktreeBranch,
    initialPrompt: String?
  )
}

extension CLISessionsViewModel: VoiceSessionManaging {
  public var voiceSessions: [CLISession] {
    var sessions = allSessions
    for item in monitoredSessions
      where !sessions.contains(where: { $0.id == item.session.id }) {
      sessions.append(item.session)
    }
    return sessions
  }

  public func voiceStartNewSessionInHub(
    _ worktree: WorktreeBranch,
    initialPrompt: String?
  ) {
    startNewSessionInHub(worktree, initialPrompt: initialPrompt)
  }
}

@MainActor
public protocol VoiceAgentToolExecuting: AnyObject {
  func listSessions() -> VoiceSessionsSummary
  func sessionStatus(sessionId: String) -> VoiceSessionStatusDetail?
  func sendPrompt(sessionId: String, prompt: String) -> VoicePromptDeliveryResult
  func focusSession(sessionId: String) -> Bool
  func launchSession(
    worktreePath: String,
    provider: SessionProviderKind,
    prompt: String?
  ) -> VoiceLaunchResult
  func pendingApproval(sessionId: String) -> VoicePendingApproval?
  func respondToApproval(
    sessionId: String,
    approve: Bool
  ) -> VoiceApprovalResponseResult
  func completionStream(sessionId: String) -> AsyncStream<SessionStatus>
  func latestResponse(sessionId: String?) async -> VoiceLatestResponse?
}

@MainActor
public final class VoiceAgentToolExecutor: VoiceAgentToolExecuting {
  private let claudeViewModel: any VoiceSessionManaging
  private let codexViewModel: any VoiceSessionManaging
  private let selectionRouter: GlobalSessionSelectionRouter
  private let targetResolver: any VoiceSessionTargetResolving
  private let transcriptReader: any VoiceSessionTranscriptReading
  private let snapshotProvider: (@MainActor () -> SessionInvestigationSnapshot)?

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    selectionRouter: GlobalSessionSelectionRouter,
    targetResolver: any VoiceSessionTargetResolving,
    transcriptReader: any VoiceSessionTranscriptReading = VoiceSessionTranscriptReader()
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.selectionRouter = selectionRouter
    self.targetResolver = targetResolver
    self.transcriptReader = transcriptReader
    snapshotProvider = {
      SessionInvestigationSnapshotBuilder.make(
        claudeViewModel: claudeViewModel,
        codexViewModel: codexViewModel
      )
    }
  }

  public init(
    claudeViewModel: any VoiceSessionManaging,
    codexViewModel: any VoiceSessionManaging,
    selectionRouter: GlobalSessionSelectionRouter,
    targetResolver: any VoiceSessionTargetResolving,
    transcriptReader: any VoiceSessionTranscriptReading = VoiceSessionTranscriptReader()
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.selectionRouter = selectionRouter
    self.targetResolver = targetResolver
    self.transcriptReader = transcriptReader
    snapshotProvider = nil
  }

  public func listSessions() -> VoiceSessionsSummary {
    let generatedAt = Date()
    let sessions: [VoiceSessionSummary]
    if let snapshot = snapshotProvider?() {
      sessions = snapshot.sessions.map { session in
        let state = viewModel(for: session.provider).monitorStates[session.id]
        return VoiceSessionSummary(
          id: session.id,
          name: session.displayName,
          provider: session.provider,
          worktree: session.worktreePath ?? session.projectPath,
          status: session.status ?? (session.isActive ? "Active" : "Idle"),
          pendingApprovalTool: state?.pendingToolUse?.toolName,
          secondsSinceActivity: max(
            0,
            Int(generatedAt.timeIntervalSince(session.lastActivityAt))
          ),
          localhostURL: session.localhostURL
        )
      }
    } else {
      sessions = [claudeViewModel, codexViewModel].flatMap { viewModel in
        viewModel.voiceSessions.map { session in
          let state = viewModel.monitorStates[session.id]
          return VoiceSessionSummary(
            id: session.id,
            name: viewModel.sessionCustomNames[session.id] ?? session.displayName,
            provider: viewModel.providerKind,
            worktree: session.projectPath,
            status: state?.status.displayName
              ?? (session.isActive ? "Active" : "Idle"),
            pendingApprovalTool: state?.pendingToolUse?.toolName,
            secondsSinceActivity: max(
              0,
              Int(generatedAt.timeIntervalSince(
                state?.lastActivityAt ?? session.lastActivityAt
              ))
            ),
            localhostURL: state?.detectedLocalhostURL?.absoluteString
          )
        }
      }
    }
    return VoiceSessionsSummary(
      sessions: sessions,
      targetSessionId: targetResolver.resolve(manualSessionId: nil)?.sessionId
    )
  }

  public func sessionStatus(sessionId: String) -> VoiceSessionStatusDetail? {
    if let resolvedSessionId = resolvedSessionID(forPendingID: sessionId) {
      return sessionStatus(sessionId: resolvedSessionId)
    }
    guard let record = record(sessionId: sessionId) else {
      return nil
    }
    let state = record.viewModel.monitorStates[sessionId]
    let activities = Array(state?.recentActivities.suffix(3) ?? []).map { activity in
      VoiceSessionActivity(
        timestamp: activity.timestamp,
        description: Self.truncate(activity.description, limit: 200)
      )
    }
    return VoiceSessionStatusDetail(
      sessionId: sessionId,
      provider: record.provider,
      name: record.viewModel.sessionCustomNames[sessionId] ?? record.session.displayName,
      status: state?.status.displayName
        ?? (record.session.isActive ? "Active" : "Idle"),
      currentTool: state?.currentTool,
      contextUsagePercent: state.map {
        $0.contextWindowUsagePercentage * 100
      },
      pendingApproval: pendingApproval(sessionId: sessionId),
      recentActivities: activities
    )
  }

  public func sendPrompt(
    sessionId: String,
    prompt: String
  ) -> VoicePromptDeliveryResult {
    guard let record = record(sessionId: sessionId) else {
      return VoicePromptDeliveryResult(
        status: "not_found",
        sessionId: sessionId,
        usedExistingTerminal: false
      )
    }
    let usedExisting = record.viewModel.sendPromptToActiveTerminal(
      forKey: sessionId,
      prompt: prompt
    )
    if !usedExisting {
      record.viewModel.showTerminalWithPrompt(
        for: record.session,
        prompt: prompt
      )
    }
    return VoicePromptDeliveryResult(
      status: "accepted",
      sessionId: sessionId,
      usedExistingTerminal: usedExisting
    )
  }

  public func focusSession(sessionId: String) -> Bool {
    guard let record = record(sessionId: sessionId) else {
      return false
    }
    selectionRouter.select(
      providerKind: record.provider,
      sessionId: sessionId,
      projectPath: record.session.projectPath
    )
    record.viewModel.focusTerminal(forKey: sessionId)
    return true
  }

  public func launchSession(
    worktreePath: String,
    provider: SessionProviderKind,
    prompt: String?
  ) -> VoiceLaunchResult {
    let viewModel = viewModel(for: provider)
    guard let worktree = resolveWorktree(
      path: worktreePath,
      in: viewModel.selectedRepositories
    ) else {
      return VoiceLaunchResult(
        status: "not_found",
        provider: provider,
        worktreePath: worktreePath,
        pendingSessionId: nil
      )
    }

    viewModel.voiceStartNewSessionInHub(worktree, initialPrompt: prompt)
    return VoiceLaunchResult(
      status: "accepted",
      provider: provider,
      worktreePath: worktreePath,
      pendingSessionId: viewModel.lastCreatedPendingId?.uuidString
    )
  }

  public func pendingApproval(sessionId: String) -> VoicePendingApproval? {
    guard let record = record(sessionId: sessionId),
          record.provider == .claude,
          let pending = record.viewModel.monitorStates[sessionId]?.pendingToolUse else {
      return nil
    }
    return VoicePendingApproval(
      sessionId: sessionId,
      provider: .claude,
      toolName: pending.toolName,
      toolUseId: pending.toolUseId,
      detail: pending.input
    )
  }

  public func respondToApproval(
    sessionId: String,
    approve: Bool
  ) -> VoiceApprovalResponseResult {
    guard let record = record(sessionId: sessionId),
          record.provider == .claude,
          pendingApproval(sessionId: sessionId) != nil else {
      return VoiceApprovalResponseResult(
        status: "rejected",
        sessionId: sessionId,
        decision: approve ? "approve" : "deny"
      )
    }
    record.viewModel.showTerminalWithPrompt(
      for: record.session,
      prompt: approve ? "1" : "3"
    )
    return VoiceApprovalResponseResult(
      status: "accepted",
      sessionId: sessionId,
      decision: approve ? "approve" : "deny"
    )
  }

  public func completionStream(
    sessionId: String
  ) -> AsyncStream<SessionStatus> {
    if let record = record(sessionId: sessionId) {
      return SessionStatusObserver { [weak viewModel = record.viewModel] in
        viewModel?.sessionStatuses[sessionId]
      }.statusStream()
    }
    guard let pendingID = UUID(uuidString: sessionId),
          let viewModel = pendingViewModel(for: pendingID) else {
      return AsyncStream { $0.finish() }
    }
    return SessionStatusObserver { [weak viewModel] in
      guard let resolvedID = viewModel?.resolvedPendingSessions[pendingID] else {
        return nil
      }
      return viewModel?.sessionStatuses[resolvedID]
    }.statusStream()
  }

  public func latestResponse(sessionId: String?) async -> VoiceLatestResponse? {
    guard var lookupId = sessionId
      ?? targetResolver.resolve(manualSessionId: nil)?.sessionId else {
      return nil
    }
    if let realId = resolvedSessionID(forPendingID: lookupId) {
      lookupId = realId
    }
    guard let record = record(sessionId: lookupId) else { return nil }
    let path: String? =
      switch record.provider {
      case .claude:
        WebPreviewAgentURLResolver.sessionFilePath(for: record.session)
      case .codex:
        record.session.sessionFilePath
      }
    guard let path else { return nil }
    guard let text = await transcriptReader.latestAssistantText(
      atPath: path,
      provider: record.provider
    ), !text.isEmpty else {
      return nil
    }
    return VoiceLatestResponse(
      sessionId: lookupId,
      provider: record.provider,
      name: record.viewModel.sessionCustomNames[lookupId]
        ?? record.session.displayName,
      text: text
    )
  }

  private func record(
    sessionId: String
  ) -> (
    session: CLISession,
    provider: SessionProviderKind,
    viewModel: any VoiceSessionManaging
  )? {
    if let session = session(id: sessionId, in: claudeViewModel) {
      return (session, .claude, claudeViewModel)
    }
    if let session = session(id: sessionId, in: codexViewModel) {
      return (session, .codex, codexViewModel)
    }
    return nil
  }

  private func session(
    id: String,
    in viewModel: any VoiceSessionManaging
  ) -> CLISession? {
    viewModel.voiceSessions.first(where: { $0.id == id })
  }

  private func viewModel(
    for provider: SessionProviderKind
  ) -> any VoiceSessionManaging {
    provider == .claude ? claudeViewModel : codexViewModel
  }

  private func resolvedSessionID(forPendingID rawValue: String) -> String? {
    guard let pendingID = UUID(uuidString: rawValue) else { return nil }
    for viewModel in [claudeViewModel, codexViewModel] {
      if let sessionID = viewModel.resolvedPendingSessions[pendingID] {
        return sessionID
      }
    }
    return nil
  }

  private func pendingViewModel(
    for pendingID: UUID
  ) -> (any VoiceSessionManaging)? {
    [claudeViewModel, codexViewModel].first { viewModel in
      viewModel.pendingHubSessions.contains(where: { $0.id == pendingID })
        || viewModel.resolvedPendingSessions[pendingID] != nil
        || viewModel.lastCreatedPendingId == pendingID
    }
  }

  private func resolveWorktree(
    path: String,
    in repositories: [SelectedRepository]
  ) -> WorktreeBranch? {
    for repository in repositories {
      if let worktree = repository.worktrees.first(where: { $0.path == path }) {
        return worktree
      }
      if repository.path == path {
        return WorktreeBranch(
          name: repository.name,
          path: repository.path,
          isWorktree: false
        )
      }
    }
    return nil
  }

  private static func truncate(_ text: String, limit: Int) -> String {
    let normalized = text
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > limit else { return normalized }
    return String(normalized.prefix(limit)) + "..."
  }
}
