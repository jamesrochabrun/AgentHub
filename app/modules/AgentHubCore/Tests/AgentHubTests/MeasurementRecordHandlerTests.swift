import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("MeasurementRecordHandler")
struct MeasurementRecordHandlerTests {
  @Test("Routes to the recording provider using the explicit session id")
  func routesUsingExplicitSessionId() async throws {
    let claude = MeasurementRecordTargetMock()
    let codex = MeasurementRecordTargetMock()
    let handler = MeasurementRecordHandler(claudeTarget: claude, codexTarget: codex)

    try await handler.handle(makeMeasurement(
      id: "measurement-1",
      sourceProvider: .codex,
      sourceSessionId: "codex-session",
      sourceProcessId: 42
    ))

    #expect(claude.stored.isEmpty)
    #expect(codex.stored.map(\.sessionId) == ["codex-session"])
    #expect(codex.stored.first?.measurementId == "measurement-1")
  }

  @Test("Resolves the session by process id when the environment had none")
  func resolvesSessionByProcessId() async throws {
    let claude = MeasurementRecordTargetMock(sessionIdsByProcessId: [84: "resolved-session"])
    let codex = MeasurementRecordTargetMock()
    let handler = MeasurementRecordHandler(claudeTarget: claude, codexTarget: codex)

    try await handler.handle(makeMeasurement(
      id: "measurement-1",
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 84
    ))

    #expect(claude.stored.map(\.sessionId) == ["resolved-session"])
    #expect(codex.stored.isEmpty)
  }

  /// A `pending-` id is replaced once the session becomes real, so storing
  /// against it would strand the card under an id nothing renders.
  @Test("Falls back from a pending session id to process resolution")
  func fallsBackFromPendingSessionId() async throws {
    let claude = MeasurementRecordTargetMock(sessionIdsByProcessId: [84: "resolved-session"])
    let handler = MeasurementRecordHandler(claudeTarget: claude, codexTarget: MeasurementRecordTargetMock())

    try await handler.handle(makeMeasurement(
      id: "measurement-1",
      sourceProvider: .claude,
      sourceSessionId: "pending-123",
      sourceProcessId: 84
    ))

    #expect(claude.stored.map(\.sessionId) == ["resolved-session"])
  }

  @Test("Throws when no session can be resolved, so the record stays queued")
  func throwsWhenSessionUnresolved() async {
    let target = MeasurementRecordTargetMock()
    let handler = MeasurementRecordHandler(claudeTarget: target, codexTarget: target)

    await #expect(throws: MeasurementRecordHandlingError.self) {
      try await handler.handle(makeMeasurement(
        id: "measurement-1",
        sourceProvider: .claude,
        sourceSessionId: nil,
        sourceProcessId: 1
      ))
    }
    #expect(target.stored.isEmpty)
  }
}

@MainActor
private final class MeasurementRecordTargetMock: MeasurementRecordTarget {
  struct Stored: Equatable {
    let measurementId: String
    let sessionId: String
  }

  let sessionIdsByProcessId: [Int32: String]
  private(set) var stored: [Stored] = []

  init(sessionIdsByProcessId: [Int32: String] = [:]) {
    self.sessionIdsByProcessId = sessionIdsByProcessId
  }

  func activeSessionId(forProcessId processId: Int32) -> String? {
    sessionIdsByProcessId[processId]
  }

  func storeMeasurement(_ measurement: MeasurementRecord, forSessionId sessionId: String) {
    stored.append(Stored(measurementId: measurement.id, sessionId: sessionId))
  }
}

private func makeMeasurement(
  id: String,
  sourceProvider: WorktreeLaunchProvider,
  sourceSessionId: String?,
  sourceProcessId: Int32
) -> MeasurementRecord {
  MeasurementRecord(
    id: id,
    title: "Week-2 retention by channel",
    claim: "Referral retains at 41% versus 22% for paid.",
    chart: MeasurementChart(
      kind: .bar,
      series: [
        MeasurementSeries(name: "Week 2", points: [MeasurementPoint(x: "referral", y: 41)])
      ]
    ),
    sourceProvider: sourceProvider,
    sourceSessionId: sourceSessionId,
    sourceProcessId: sourceProcessId
  )
}
