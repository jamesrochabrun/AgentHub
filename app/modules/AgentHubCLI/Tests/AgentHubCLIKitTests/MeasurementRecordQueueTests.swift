import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("MeasurementRecordQueue")
struct MeasurementRecordQueueTests {
  @Test("Enqueue writes the record and preserves the full payload")
  func enqueuePreservesPayload() throws {
    let directory = try temporaryMeasurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = MeasurementRecordQueue(directoryURL: directory)
    let record = makeRecord(id: "measurement-1")

    let queued = try queue.enqueue(record)
    let pending = try queue.pendingRecords()

    #expect(FileManager.default.fileExists(atPath: queued.fileURL.path))
    #expect(pending.map(\.record) == [record])
  }

  @Test("Chart, table and caveats survive the round trip")
  func chartAndTableSurviveRoundTrip() throws {
    let directory = try temporaryMeasurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = MeasurementRecordQueue(directoryURL: directory)
    try queue.enqueue(makeRecord(id: "measurement-1"))

    let decoded = try #require(try queue.pendingRecords().first?.record)
    #expect(decoded.chart?.kind == .bar)
    #expect(decoded.chart?.series.count == 2)
    #expect(decoded.chart?.series.first?.points == [
      MeasurementPoint(x: "referral", y: 41),
      MeasurementPoint(x: "paid", y: 22),
    ])
    #expect(decoded.table?.columns == ["channel", "users"])
    #expect(decoded.table?.rows == [["referral", "3100"]])
    #expect(decoded.caveats == ["Excludes trial accounts"])
  }

  @Test("Pending records are ordered oldest first")
  func pendingRecordsAreOrderedOldestFirst() throws {
    let directory = try temporaryMeasurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = MeasurementRecordQueue(directoryURL: directory)
    try queue.enqueue(makeRecord(id: "newer", createdAt: Date(timeIntervalSince1970: 9_000)))
    try queue.enqueue(makeRecord(id: "older", createdAt: Date(timeIntervalSince1970: 1_000)))

    #expect(try queue.pendingRecords().map(\.record.id) == ["older", "newer"])
  }

  @Test("Remove deletes a handled record")
  func removeDeletesHandledRecord() throws {
    let directory = try temporaryMeasurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = MeasurementRecordQueue(directoryURL: directory)
    let queued = try queue.enqueue(makeRecord(id: "measurement-1"))

    try queue.remove(queued)

    #expect(try queue.pendingRecords().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: queued.fileURL.path))
  }

  @Test("Mark failed moves the record out of the pending queue")
  func markFailedMovesRecordOut() throws {
    let directory = try temporaryMeasurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = MeasurementRecordQueue(directoryURL: directory)
    let queued = try queue.enqueue(makeRecord(id: "measurement-1"))

    try queue.markFailed(queued)

    let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
    #expect(try queue.pendingRecords().isEmpty)
    #expect(FileManager.default.fileExists(atPath: failedURL.path))
  }
}

private func makeRecord(
  id: String,
  createdAt: Date = Date(timeIntervalSince1970: 3_000)
) -> MeasurementRecord {
  MeasurementRecord(
    id: id,
    createdAt: createdAt,
    title: "Week-2 retention by channel",
    claim: "Referral retains at 41% versus 22% for paid.",
    question: "Which acquisition channel retains best?",
    query: "select channel, count(*) from signups group by 1",
    source: "analytics.signups",
    caveats: ["Excludes trial accounts"],
    chart: MeasurementChart(
      kind: .bar,
      xLabel: "Channel",
      yLabel: "Retention %",
      series: [
        MeasurementSeries(name: "Week 2", points: [
          MeasurementPoint(x: "referral", y: 41),
          MeasurementPoint(x: "paid", y: 22),
        ]),
        MeasurementSeries(name: "Week 4", points: [
          MeasurementPoint(x: "referral", y: 33),
          MeasurementPoint(x: "paid", y: 15),
        ]),
      ]
    ),
    table: MeasurementTable(columns: ["channel", "users"], rows: [["referral", "3100"]]),
    sourceProvider: .claude,
    sourceSessionId: "session-1",
    sourceProjectPath: "/tmp/project",
    sourceProcessId: 42
  )
}

private func temporaryMeasurementDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-measurement-record-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("records", isDirectory: true)
}
