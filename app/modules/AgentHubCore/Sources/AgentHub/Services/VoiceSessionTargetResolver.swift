import Foundation

@MainActor
public protocol VoiceSessionTargetResolving: AnyObject {
  func resolve(manualSessionId: String?) -> VoiceSessionTarget?
  func candidates() -> [VoiceSessionTarget]
}

@MainActor
public protocol VoiceSessionTargetSource: AnyObject {
  var providerKind: SessionProviderKind { get }
  var voiceTargetCandidates: [VoiceSessionTarget] { get }
  var lastFocusedSessionId: String? { get }
  var lastFocusedSessionAt: Date? { get }
}

extension CLISessionsViewModel: VoiceSessionTargetSource {
  public var voiceTargetCandidates: [VoiceSessionTarget] {
    var sessions = allSessions
    for item in monitoredSessions
      where !sessions.contains(where: { $0.id == item.session.id }) {
      sessions.append(item.session)
    }

    var seen = Set<String>()
    return sessions.compactMap { session in
      guard seen.insert(session.id).inserted else { return nil }
      return VoiceSessionTarget(
        sessionId: session.id,
        provider: providerKind,
        name: sessionCustomNames[session.id] ?? session.displayName,
        projectPath: session.projectPath,
        lastActivityAt: monitorStates[session.id]?.lastActivityAt
          ?? session.lastActivityAt
      )
    }
  }
}

@MainActor
public final class VoiceSessionTargetResolver: VoiceSessionTargetResolving {
  private let claudeViewModel: any VoiceSessionTargetSource
  private let codexViewModel: any VoiceSessionTargetSource
  private let selectionRouter: GlobalSessionSelectionRouter

  public init(
    claudeViewModel: any VoiceSessionTargetSource,
    codexViewModel: any VoiceSessionTargetSource,
    selectionRouter: GlobalSessionSelectionRouter
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.selectionRouter = selectionRouter
  }

  public func resolve(manualSessionId: String? = nil) -> VoiceSessionTarget? {
    let targets = candidates()
    if let manualSessionId,
       let manual = targets.first(where: { $0.sessionId == manualSessionId }) {
      return manual
    }

    let lastFocused = [
      focusedTarget(viewModel: claudeViewModel, provider: .claude, targets: targets),
      focusedTarget(viewModel: codexViewModel, provider: .codex, targets: targets),
    ]
      .compactMap { $0 }
      .max { $0.date < $1.date }
    if let lastFocused {
      return lastFocused.target
    }

    if let request = selectionRouter.selectionRequest,
       let selected = targets.first(where: {
         $0.sessionId == request.sessionId && $0.provider == request.providerKind
       }) {
      return selected
    }

    return targets.max { $0.lastActivityAt < $1.lastActivityAt }
  }

  public func candidates() -> [VoiceSessionTarget] {
    claudeViewModel.voiceTargetCandidates
      + codexViewModel.voiceTargetCandidates
  }

  private func focusedTarget(
    viewModel: any VoiceSessionTargetSource,
    provider: SessionProviderKind,
    targets: [VoiceSessionTarget]
  ) -> (target: VoiceSessionTarget, date: Date)? {
    guard let id = viewModel.lastFocusedSessionId,
          let date = viewModel.lastFocusedSessionAt,
          let target = targets.first(where: {
            $0.sessionId == id && $0.provider == provider
          }) else {
      return nil
    }
    return (target, date)
  }
}
