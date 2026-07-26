import AgentHubCLIKit
import Foundation

@MainActor
public protocol SessionNameRequestTarget: AnyObject {
  func activeSessionId(forProcessId processId: Int32) -> String?
  func setCustomName(_ name: String?, forSessionId sessionId: String)
}

@MainActor
public protocol SessionNameRequestHandlingProtocol: AnyObject {
  func handle(_ request: SessionNameRequest) async throws
}

enum SessionNameRequestHandlingError: LocalizedError {
  case emptyName
  case sessionUnavailable

  var errorDescription: String? {
    switch self {
    case .emptyName:
      return "The selected session name is empty."
    case .sessionUnavailable:
      return "The AgentHub session that requested the name could not be found."
    }
  }
}

@MainActor
public final class SessionNameRequestHandler: SessionNameRequestHandlingProtocol {
  private let claudeTarget: any SessionNameRequestTarget
  private let codexTarget: any SessionNameRequestTarget

  public init(
    claudeTarget: any SessionNameRequestTarget,
    codexTarget: any SessionNameRequestTarget
  ) {
    self.claudeTarget = claudeTarget
    self.codexTarget = codexTarget
  }

  public func handle(_ request: SessionNameRequest) async throws {
    guard let name = SessionNameFormatter.format(request.name) else {
      throw SessionNameRequestHandlingError.emptyName
    }

    let target: any SessionNameRequestTarget
    switch request.sourceProvider {
    case .claude:
      target = claudeTarget
    case .codex:
      target = codexTarget
    }

    let explicitSessionId = request.sourceSessionId.flatMap { sessionId in
      sessionId.hasPrefix("pending-") ? nil : sessionId
    }
    let sessionId = explicitSessionId
      ?? target.activeSessionId(forProcessId: request.sourceProcessId)
    guard let sessionId, !sessionId.hasPrefix("pending-") else {
      throw SessionNameRequestHandlingError.sessionUnavailable
    }

    target.setCustomName(name, forSessionId: sessionId)
  }
}

extension CLISessionsViewModel: SessionNameRequestTarget {}

enum SessionProcessGroupMatcher {
  struct Candidate {
    let sessionId: String
    let processId: Int32
  }

  static func sessionId(
    for sourceProcessId: Int32,
    candidates: [Candidate],
    processGroupId: (Int32) -> Int32?
  ) -> String? {
    if let exact = candidates.first(where: { $0.processId == sourceProcessId }) {
      return exact.sessionId
    }

    guard let sourceProcessGroupId = processGroupId(sourceProcessId) else {
      return nil
    }
    return candidates.first { candidate in
      processGroupId(candidate.processId) == sourceProcessGroupId
    }?.sessionId
  }
}
