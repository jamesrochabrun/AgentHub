import Foundation

/// Terminal outcome of one `SimulatorRunRequest`, written by the app after the
/// Build & Run finishes so the MCP server (and therefore the agent) can read
/// real success/failure instead of fire-and-forget.
public struct SimulatorRunResult: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case succeeded
    case failed
  }

  public let requestId: String
  public let status: Status
  public let projectPath: String
  /// The device the run actually targeted (resolved by the app when the
  /// request omitted one).
  public let udid: String?
  /// Build/boot/launch error text when `status == .failed`.
  public let errorMessage: String?
  /// True when the launch armed hot reload, so subsequent saved Swift files
  /// hot-swap into the running app without another explicit run.
  public let hotReloadArmed: Bool
  public let finishedAt: Date

  public init(
    requestId: String,
    status: Status,
    projectPath: String,
    udid: String?,
    errorMessage: String? = nil,
    hotReloadArmed: Bool = false,
    finishedAt: Date = Date()
  ) {
    self.requestId = requestId
    self.status = status
    self.projectPath = projectPath
    self.udid = udid
    self.errorMessage = errorMessage
    self.hotReloadArmed = hotReloadArmed
    self.finishedAt = finishedAt
  }
}

/// One JSON file per finished request, sibling of `simulator-run-requests`.
/// The app is the only writer; the bundled `agenthub` MCP server polls
/// `waitForResult` so `agenthub_simulator_run` can report the outcome.
public struct SimulatorRunResultStore: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = SimulatorRunResultStore.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("simulator-run-results", isDirectory: true)
  }

  public func write(_ result: SimulatorRunResult) throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(result)

    let finalURL = fileURL(requestId: result.requestId)
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(result.requestId).tmp", isDirectory: false
    )

    try data.write(to: temporaryURL, options: [.atomic])
    if FileManager.default.fileExists(atPath: finalURL.path) {
      try FileManager.default.removeItem(at: finalURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
  }

  public func result(requestId: String) -> SimulatorRunResult? {
    let url = fileURL(requestId: requestId)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SimulatorRunResult.self, from: data)
  }

  /// Polls until a result for `requestId` appears or `timeout` elapses.
  /// Returns nil on timeout — the run may still be building.
  public func waitForResult(
    requestId: String,
    timeout: Duration,
    pollInterval: Duration = .seconds(1)
  ) async -> SimulatorRunResult? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
      if let result = result(requestId: requestId) {
        return result
      }
      if clock.now >= deadline || Task.isCancelled {
        return nil
      }
      try? await Task.sleep(for: pollInterval)
    }
  }

  /// Deletes result files older than `age`. Results are one-shot handshakes;
  /// anything old is a leftover from a reader that never came back.
  public func prune(olderThan age: TimeInterval, now: Date = Date()) {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }

    for url in files {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      if now.timeIntervalSince(modified) > age {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  public func fileURL(requestId: String) -> URL {
    directoryURL.appendingPathComponent("\(requestId).json", isDirectory: false)
  }
}
