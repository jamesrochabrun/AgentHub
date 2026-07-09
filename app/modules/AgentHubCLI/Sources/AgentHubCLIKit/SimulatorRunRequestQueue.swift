import Foundation

public enum SimulatorRunRequestMode: String, Codable, Equatable, Sendable {
  case buildAndRun
}

public struct SimulatorRunRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let createdAt: Date
  public let projectPath: String
  /// Nil asks the app to resolve the project's persisted run destination
  /// (the same per-project preference the Simulator panel uses).
  public let udid: String?
  public let mode: SimulatorRunRequestMode
  public let sourceProvider: WorktreeLaunchProvider?
  public let sourceSessionId: String?
  public let reason: String?

  public init(
    id: String = UUID().uuidString,
    createdAt: Date = Date(),
    projectPath: String,
    udid: String? = nil,
    mode: SimulatorRunRequestMode = .buildAndRun,
    sourceProvider: WorktreeLaunchProvider? = nil,
    sourceSessionId: String? = nil,
    reason: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.projectPath = projectPath
    self.udid = udid
    self.mode = mode
    self.sourceProvider = sourceProvider
    self.sourceSessionId = sourceSessionId
    self.reason = reason
  }
}

public struct QueuedSimulatorRunRequest: Equatable, Sendable {
  public let request: SimulatorRunRequest
  public let fileURL: URL

  public init(request: SimulatorRunRequest, fileURL: URL) {
    self.request = request
    self.fileURL = fileURL
  }
}

public struct SimulatorRunRequestQueue: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = SimulatorRunRequestQueue.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("simulator-run-requests", isDirectory: true)
  }

  @discardableResult
  public func enqueue(_ request: SimulatorRunRequest) throws -> QueuedSimulatorRunRequest {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(request)

    let finalURL = directoryURL.appendingPathComponent("\(request.id).json", isDirectory: false)
    let temporaryURL = directoryURL.appendingPathComponent(".\(request.id).tmp", isDirectory: false)

    try data.write(to: temporaryURL, options: [.atomic])
    if FileManager.default.fileExists(atPath: finalURL.path) {
      try FileManager.default.removeItem(at: finalURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

    return QueuedSimulatorRunRequest(request: request, fileURL: finalURL)
  }

  public func pendingRequests() throws -> [QueuedSimulatorRunRequest] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else {
      return []
    }

    let files = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    )

    let decoder = JSONDecoder()
    return files
      .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
      .compactMap { url in
        guard let data = try? Data(contentsOf: url),
              let request = try? decoder.decode(SimulatorRunRequest.self, from: data) else {
          return nil
        }
        return QueuedSimulatorRunRequest(request: request, fileURL: url)
      }
      .sorted {
        if $0.request.createdAt == $1.request.createdAt {
          return $0.request.id < $1.request.id
        }
        return $0.request.createdAt < $1.request.createdAt
      }
  }

  public func remove(_ queued: QueuedSimulatorRunRequest) throws {
    guard FileManager.default.fileExists(atPath: queued.fileURL.path) else { return }
    try FileManager.default.removeItem(at: queued.fileURL)
  }

  public func markFailed(_ queued: QueuedSimulatorRunRequest) throws {
    guard FileManager.default.fileExists(atPath: queued.fileURL.path) else { return }
    let failedURL = queued.fileURL
      .deletingPathExtension()
      .appendingPathExtension("failed")
    if FileManager.default.fileExists(atPath: failedURL.path) {
      try FileManager.default.removeItem(at: failedURL)
    }
    try FileManager.default.moveItem(at: queued.fileURL, to: failedURL)
  }

  /// Deletes `.failed` markers older than `age` — they exist only so a
  /// just-queued run can report failure, and would otherwise accumulate.
  public func pruneFailed(olderThan age: TimeInterval, now: Date = Date()) {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }

    for url in files where url.pathExtension == "failed" {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      if now.timeIntervalSince(modified) > age {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
}
