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
    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw SessionNameRequestHandlingError.emptyName
    }

    let target: any SessionNameRequestTarget
    switch request.sourceProvider {
    case .claude:
      target = claudeTarget
    case .codex:
      target = codexTarget
    }

    let sessionId = request.sourceSessionId
      ?? target.activeSessionId(forProcessId: request.sourceProcessId)
    guard let sessionId, !sessionId.hasPrefix("pending-") else {
      throw SessionNameRequestHandlingError.sessionUnavailable
    }

    target.setCustomName(name, forSessionId: sessionId)
  }
}

extension CLISessionsViewModel: SessionNameRequestTarget {}
