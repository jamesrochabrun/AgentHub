import Foundation

public struct QueuedMeasurementRecord: Equatable, Sendable {
  public let record: MeasurementRecord
  public let fileURL: URL

  public init(record: MeasurementRecord, fileURL: URL) {
    self.record = record
    self.fileURL = fileURL
  }
}

/// File-backed handoff from the `agenthub` CLI's MCP server to the app.
///
/// The CLI runs as a separate process, so it cannot write the app's SQLite store
/// directly; it drops a JSON file here and the app drains it (same shape as
/// `SessionNameRequestQueue`). Writes are atomic-then-move so the app never
/// reads a half-written record.
public struct MeasurementRecordQueue: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = MeasurementRecordQueue.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("measurement-records", isDirectory: true)
  }

  @discardableResult
  public func enqueue(_ record: MeasurementRecord) throws -> QueuedMeasurementRecord {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(record)

    let finalURL = directoryURL.appendingPathComponent("\(record.id).json", isDirectory: false)
    let temporaryURL = directoryURL.appendingPathComponent(".\(record.id).tmp", isDirectory: false)

    try data.write(to: temporaryURL, options: [.atomic])
    if FileManager.default.fileExists(atPath: finalURL.path) {
      try FileManager.default.removeItem(at: finalURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

    return QueuedMeasurementRecord(record: record, fileURL: finalURL)
  }

  public func pendingRecords() throws -> [QueuedMeasurementRecord] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else {
      return []
    }

    let files = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return files
      .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
      .compactMap { url in
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder.decode(MeasurementRecord.self, from: data)
        else {
          return nil
        }
        return QueuedMeasurementRecord(record: record, fileURL: url)
      }
      .sorted {
        if $0.record.createdAt == $1.record.createdAt {
          return $0.record.id < $1.record.id
        }
        return $0.record.createdAt < $1.record.createdAt
      }
  }

  public func remove(_ queued: QueuedMeasurementRecord) throws {
    guard FileManager.default.fileExists(atPath: queued.fileURL.path) else { return }
    try FileManager.default.removeItem(at: queued.fileURL)
  }

  public func markFailed(_ queued: QueuedMeasurementRecord) throws {
    guard FileManager.default.fileExists(atPath: queued.fileURL.path) else { return }
    let failedURL = queued.fileURL
      .deletingPathExtension()
      .appendingPathExtension("failed")
    if FileManager.default.fileExists(atPath: failedURL.path) {
      try FileManager.default.removeItem(at: failedURL)
    }
    try FileManager.default.moveItem(at: queued.fileURL, to: failedURL)
  }
}
