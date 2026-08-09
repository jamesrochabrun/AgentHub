import Foundation

/// A compact, agent-readable summary of one measurement.
public struct MeasurementIndexEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let title: String
  public let question: String?
  /// The command that produced it. Present so an agent asked to refresh can run
  /// the original measurement rather than writing a new one that happens to
  /// answer the same question differently.
  public let query: String?
  public let source: String?
  public let lastRunAt: Date
  public let runCount: Int
  public let latestClaim: String

  public init(
    id: String,
    title: String,
    question: String?,
    query: String?,
    source: String?,
    lastRunAt: Date,
    runCount: Int,
    latestClaim: String
  ) {
    self.id = id
    self.title = title
    self.question = question
    self.query = query
    self.source = source
    self.lastRunAt = lastRunAt
    self.runCount = runCount
    self.latestClaim = latestClaim
  }

  public init(measurement: MeasurementRecord) {
    self.init(
      id: measurement.id,
      title: measurement.title,
      question: measurement.question,
      query: measurement.query,
      source: measurement.source,
      lastRunAt: measurement.displayDate,
      runCount: measurement.runs.count,
      latestClaim: measurement.claim
    )
  }
}

public struct MeasurementIndex: Codable, Equatable, Sendable {
  public let projectPath: String
  public let updatedAt: Date
  public let measurements: [MeasurementIndexEntry]

  public init(projectPath: String, updatedAt: Date, measurements: [MeasurementIndexEntry]) {
    self.projectPath = projectPath
    self.updatedAt = updatedAt
    self.measurements = measurements
  }
}

/// A read-only view of a project's measurements, for the `agenthub` CLI.
///
/// The CLI runs as a separate process and deliberately does not open the app's
/// SQLite database — that would couple the helper to the app's schema and its
/// single-process assumptions. Instead the app republishes a small JSON index
/// whenever a project's measurements change, and the CLI only ever reads it.
///
/// The app writes the index under the project's canonical key *and* under every
/// session path that resolves to it (a worktree, say), so the CLI can look it
/// up from `AGENTHUB_PROJECT_PATH` alone without knowing about worktree rollup.
public struct MeasurementIndexStore: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = MeasurementIndexStore.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("measurement-index", isDirectory: true)
  }

  /// Filesystem-safe, collision-free file name for a project path.
  ///
  /// Percent-encoding rather than substituting separators: turning `/` into `-`
  /// makes `/a/b-c` and `/a-b/c` collide, which would silently merge two
  /// projects' measurements.
  public static func fileName(forProjectPath projectPath: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: allowed)
      ?? projectPath
    return "\(encoded).json"
  }

  public func fileURL(forProjectPath projectPath: String) -> URL {
    directoryURL.appendingPathComponent(
      Self.fileName(forProjectPath: projectPath),
      isDirectory: false
    )
  }

  public func read(projectPath: String) -> MeasurementIndex? {
    let url = fileURL(forProjectPath: projectPath)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(MeasurementIndex.self, from: data)
  }

  /// Publishes an index, mirroring it to every alias path so a worktree session
  /// finds the same list its parent repo sees.
  public func write(_ index: MeasurementIndex, aliasPaths: [String] = []) throws {
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(index)

    for path in Set([index.projectPath] + aliasPaths) where !path.isEmpty {
      let finalURL = fileURL(forProjectPath: path)
      let temporaryURL = directoryURL.appendingPathComponent(
        ".\(UUID().uuidString).tmp",
        isDirectory: false
      )
      try data.write(to: temporaryURL, options: [.atomic])
      if FileManager.default.fileExists(atPath: finalURL.path) {
        try FileManager.default.removeItem(at: finalURL)
      }
      try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }
  }
}
