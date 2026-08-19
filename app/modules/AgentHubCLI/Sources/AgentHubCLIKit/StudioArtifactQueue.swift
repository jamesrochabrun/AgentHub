import Foundation

public struct QueuedStudioArtifact: Equatable, Sendable {
  public let artifact: StudioArtifact
  public let fileURL: URL

  public init(artifact: StudioArtifact, fileURL: URL) {
    self.artifact = artifact
    self.fileURL = fileURL
  }
}

/// File-backed handoff from the `agenthub` CLI's MCP server to the app.
///
/// The CLI runs as a separate process, so it cannot write the app's SQLite store
/// or its document directory directly; it drops a JSON file here and the app
/// drains it (same shape as `MeasurementRecordQueue`). Writes are atomic-then-move
/// so the app never reads a half-written artifact.
public struct StudioArtifactQueue: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = StudioArtifactQueue.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    StudioSupportDirectory.baseURL(fileManager: fileManager)
      .appendingPathComponent("studio-records", isDirectory: true)
  }

  @discardableResult
  public func enqueue(_ artifact: StudioArtifact) throws -> QueuedStudioArtifact {
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(artifact)

    let finalURL = directoryURL.appendingPathComponent("\(artifact.id).json", isDirectory: false)
    let temporaryURL = directoryURL.appendingPathComponent(".\(artifact.id).tmp", isDirectory: false)

    try data.write(to: temporaryURL, options: [.atomic])
    if FileManager.default.fileExists(atPath: finalURL.path) {
      try FileManager.default.removeItem(at: finalURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

    return QueuedStudioArtifact(artifact: artifact, fileURL: finalURL)
  }

  public func pendingArtifacts() throws -> [QueuedStudioArtifact] {
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
              let artifact = try? decoder.decode(StudioArtifact.self, from: data)
        else {
          return nil
        }
        return QueuedStudioArtifact(artifact: artifact, fileURL: url)
      }
      .sorted {
        if $0.artifact.createdAt == $1.artifact.createdAt {
          return $0.artifact.id < $1.artifact.id
        }
        return $0.artifact.createdAt < $1.artifact.createdAt
      }
  }

  public func remove(_ queued: QueuedStudioArtifact) throws {
    guard FileManager.default.fileExists(atPath: queued.fileURL.path) else { return }
    try FileManager.default.removeItem(at: queued.fileURL)
  }

  public func markFailed(_ queued: QueuedStudioArtifact) throws {
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

/// Where Studio's CLI↔app files live.
///
/// Honors `AGENTHUB_APP_SUPPORT_DIR` so a sandboxed app (tests, or an explicit
/// redirect) and the CLI it launches agree on one directory; otherwise the real
/// Application Support folder, same as every other queue in this kit.
public enum StudioSupportDirectory {
  public static func baseURL(fileManager: FileManager = .default) -> URL {
    if let override = ProcessInfo.processInfo.environment["AGENTHUB_APP_SUPPORT_DIR"],
       !override.isEmpty
    {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
    }
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return appSupportURL.appendingPathComponent("AgentHub", isDirectory: true)
  }
}
