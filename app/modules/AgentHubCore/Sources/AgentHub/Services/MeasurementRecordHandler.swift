import AgentHubCLIKit
import Foundation

@MainActor
public protocol MeasurementRecordTarget: AnyObject {
  func activeSessionId(forProcessId processId: Int32) -> String?
  func storeMeasurement(_ measurement: MeasurementRecord, forSessionId sessionId: String)
}

@MainActor
public protocol MeasurementRecordHandlingProtocol: AnyObject {
  func handle(_ record: MeasurementRecord) async throws
}

enum MeasurementRecordHandlingError: LocalizedError {
  case sessionUnavailable

  var errorDescription: String? {
    switch self {
    case .sessionUnavailable:
      return "The AgentHub session that recorded this measurement could not be found."
    }
  }
}

/// Routes a filed measurement to the session it came from.
///
/// Resolution mirrors `SessionNameRequestHandler`: trust `AGENTHUB_SESSION_ID`
/// when it names a real session, otherwise map the calling process back to a
/// session. Measurement is never stored against a `pending-` id — that id is
/// replaced once the session is real, which would strand the card.
@MainActor
public final class MeasurementRecordHandler: MeasurementRecordHandlingProtocol {
  private let claudeTarget: any MeasurementRecordTarget
  private let codexTarget: any MeasurementRecordTarget

  public init(
    claudeTarget: any MeasurementRecordTarget,
    codexTarget: any MeasurementRecordTarget
  ) {
    self.claudeTarget = claudeTarget
    self.codexTarget = codexTarget
  }

  public func handle(_ record: MeasurementRecord) async throws {
    let target: any MeasurementRecordTarget
    switch record.sourceProvider {
    case .claude:
      target = claudeTarget
    case .codex:
      target = codexTarget
    }

    let explicitSessionId = record.sourceSessionId.flatMap { sessionId in
      sessionId.hasPrefix("pending-") ? nil : sessionId
    }
    let sessionId = explicitSessionId
      ?? target.activeSessionId(forProcessId: record.sourceProcessId)
    guard let sessionId, !sessionId.hasPrefix("pending-") else {
      throw MeasurementRecordHandlingError.sessionUnavailable
    }

    target.storeMeasurement(record, forSessionId: sessionId)
  }
}

extension CLISessionsViewModel: MeasurementRecordTarget {}
