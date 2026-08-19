import AgentHubCLIKit
import Foundation

@MainActor
public protocol StudioArtifactTarget: AnyObject {
  func activeSessionId(forProcessId processId: Int32) -> String?
  func storeStudioArtifact(_ artifact: StudioArtifact, forSessionId sessionId: String)
}

@MainActor
public protocol StudioArtifactHandlingProtocol: AnyObject {
  func handle(_ artifact: StudioArtifact) async throws
}

enum StudioArtifactHandlingError: LocalizedError {
  case sessionUnavailable

  var errorDescription: String? {
    switch self {
    case .sessionUnavailable:
      return "The AgentHub session that filed this artifact could not be found."
    }
  }
}

/// Routes a filed Studio artifact to the session it came from — Claude or Codex.
///
/// Resolution mirrors `MeasurementRecordHandler`: trust `AGENTHUB_SESSION_ID`
/// when it names a real session, otherwise map the calling process back to a
/// session. Never stored against a `pending-` id — that id is replaced once the
/// session is real, which would strand the artifact.
@MainActor
public final class StudioArtifactHandler: StudioArtifactHandlingProtocol {
  private let claudeTarget: any StudioArtifactTarget
  private let codexTarget: any StudioArtifactTarget

  public init(
    claudeTarget: any StudioArtifactTarget,
    codexTarget: any StudioArtifactTarget
  ) {
    self.claudeTarget = claudeTarget
    self.codexTarget = codexTarget
  }

  public func handle(_ artifact: StudioArtifact) async throws {
    let target: any StudioArtifactTarget
    switch artifact.sourceProvider {
    case .claude:
      target = claudeTarget
    case .codex:
      target = codexTarget
    }

    let explicitSessionId = artifact.sourceSessionId.flatMap { sessionId in
      sessionId.hasPrefix("pending-") ? nil : sessionId
    }
    let sessionId = explicitSessionId
      ?? target.activeSessionId(forProcessId: artifact.sourceProcessId)
    guard let sessionId, !sessionId.hasPrefix("pending-") else {
      throw StudioArtifactHandlingError.sessionUnavailable
    }

    target.storeStudioArtifact(artifact, forSessionId: sessionId)
  }
}

extension CLISessionsViewModel: StudioArtifactTarget {}
