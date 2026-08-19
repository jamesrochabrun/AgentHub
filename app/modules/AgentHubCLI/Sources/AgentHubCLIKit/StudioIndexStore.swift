import Foundation

/// A compact, agent-readable summary of one Studio artifact.
public struct StudioIndexEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let kind: StudioArtifactKind
  public let title: String
  public let variantNames: [String]
  public let sourcePath: String?
  public let revision: Int
  public let updatedAt: Date
  /// The served document on disk, so an agent can open what it filed.
  public let documentPath: String?
  /// The current payload (`artifact.json`) beside it — variants with the
  /// user's baked-in edits, props, sourcePath. What `agenthub_get_artifact` reads.
  public let payloadPath: String?

  public init(
    id: String,
    kind: StudioArtifactKind,
    title: String,
    variantNames: [String],
    sourcePath: String?,
    revision: Int,
    updatedAt: Date,
    documentPath: String?,
    payloadPath: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.variantNames = variantNames
    self.sourcePath = sourcePath
    self.revision = revision
    self.updatedAt = updatedAt
    self.documentPath = documentPath
    self.payloadPath = payloadPath
  }

  public init(artifact: StudioArtifact, documentPath: String?, payloadPath: String? = nil) {
    self.init(
      id: artifact.id,
      kind: artifact.kind,
      title: artifact.title,
      variantNames: artifact.variantNames,
      sourcePath: artifact.sourcePath,
      revision: artifact.revision,
      updatedAt: artifact.displayDate,
      documentPath: documentPath,
      payloadPath: payloadPath
    )
  }
}

public struct StudioIndex: Codable, Equatable, Sendable {
  public let projectPath: String
  public let updatedAt: Date
  public let artifacts: [StudioIndexEntry]

  public init(projectPath: String, updatedAt: Date, artifacts: [StudioIndexEntry]) {
    self.projectPath = projectPath
    self.updatedAt = updatedAt
    self.artifacts = artifacts
  }
}

/// A read-only view of a project's Studio artifacts, for the `agenthub` CLI.
///
/// Same contract as `MeasurementIndexStore`: the CLI never opens the app's
/// SQLite database. The app republishes this JSON index whenever a project's
/// artifacts change, mirrored to every session path that resolves to the
/// project (worktrees included), and the CLI only ever reads it.
public struct StudioIndexStore: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = StudioIndexStore.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    StudioSupportDirectory.baseURL(fileManager: fileManager)
      .appendingPathComponent("studio-index", isDirectory: true)
  }

  /// Percent-encoded rather than separator-substituted: turning `/` into `-`
  /// makes `/a/b-c` and `/a-b/c` collide, silently merging two projects.
  public static func fileName(forProjectPath projectPath: String) -> String {
    let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? projectPath
    return "\(encoded).json"
  }

  public func fileURL(forProjectPath projectPath: String) -> URL {
    directoryURL.appendingPathComponent(Self.fileName(forProjectPath: projectPath), isDirectory: false)
  }

  public func read(projectPath: String) -> StudioIndex? {
    guard let data = try? Data(contentsOf: fileURL(forProjectPath: projectPath)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(StudioIndex.self, from: data)
  }

  /// Publishes an index, mirroring it to every alias path so a worktree session
  /// finds the same list its parent repo sees.
  public func write(_ index: StudioIndex, aliasPaths: [String] = []) throws {
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(index)

    for path in Set([index.projectPath] + aliasPaths) where !path.isEmpty {
      let finalURL = fileURL(forProjectPath: path)
      let temporaryURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
      try data.write(to: temporaryURL, options: [.atomic])
      if FileManager.default.fileExists(atPath: finalURL.path) {
        try FileManager.default.removeItem(at: finalURL)
      }
      try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }
  }
}
