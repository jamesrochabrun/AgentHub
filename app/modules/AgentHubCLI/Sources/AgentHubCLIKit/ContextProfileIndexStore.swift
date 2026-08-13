import Foundation

/// A compact, agent-readable summary of one context profile.
public struct ContextProfileIndexEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  /// "personal" or "project".
  public let scope: String
  public let isDefault: Bool
  /// Project-relative paths included by the profile.
  public let relativeFilePaths: [String]
  /// Absolute paths outside the repository (documents, other repos, books).
  public let externalPaths: [String]
  /// Titles of pasted-text snippets stored in the set.
  public let textSnippetTitles: [String]
  public let instructions: String
  public let updatedAt: Date

  public init(
    id: String,
    name: String,
    scope: String,
    isDefault: Bool,
    relativeFilePaths: [String],
    externalPaths: [String] = [],
    textSnippetTitles: [String] = [],
    instructions: String,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.scope = scope
    self.isDefault = isDefault
    self.relativeFilePaths = relativeFilePaths
    self.externalPaths = externalPaths
    self.textSnippetTitles = textSnippetTitles
    self.instructions = instructions
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, scope, isDefault, relativeFilePaths, externalPaths, textSnippetTitles, instructions, updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    scope = try container.decode(String.self, forKey: .scope)
    isDefault = try container.decode(Bool.self, forKey: .isDefault)
    relativeFilePaths = try container.decode([String].self, forKey: .relativeFilePaths)
    externalPaths = try container.decodeIfPresent([String].self, forKey: .externalPaths) ?? []
    textSnippetTitles = try container.decodeIfPresent([String].self, forKey: .textSnippetTitles) ?? []
    instructions = try container.decode(String.self, forKey: .instructions)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }
}

public struct ContextProfileIndex: Codable, Equatable, Sendable {
  public let projectPath: String
  public let updatedAt: Date
  public let profiles: [ContextProfileIndexEntry]

  public init(projectPath: String, updatedAt: Date, profiles: [ContextProfileIndexEntry]) {
    self.projectPath = projectPath
    self.updatedAt = updatedAt
    self.profiles = profiles
  }
}

/// A read-only view of a project's context profiles, for the `agenthub` CLI.
///
/// The CLI runs as a separate process and deliberately does not open the app's
/// SQLite database. The app republishes this small JSON index whenever a
/// project's profiles change (personal profiles are merged into every project's
/// index at publish time), and the CLI only ever reads it.
///
/// The app writes the index under the project's canonical key *and* under every
/// session path that resolves to it (a worktree, say), so the CLI can look it
/// up from `AGENTHUB_PROJECT_PATH` alone without knowing about worktree rollup.
public struct ContextProfileIndexStore: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = ContextProfileIndexStore.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("context-index", isDirectory: true)
  }

  /// Filesystem-safe, collision-free file name for a project path.
  ///
  /// Percent-encoding rather than substituting separators: turning `/` into `-`
  /// makes `/a/b-c` and `/a-b/c` collide, which would silently merge two
  /// projects' profiles.
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

  public func read(projectPath: String) -> ContextProfileIndex? {
    let url = fileURL(forProjectPath: projectPath)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ContextProfileIndex.self, from: data)
  }

  /// Publishes an index, mirroring it to every alias path so a worktree session
  /// finds the same list its parent repo sees.
  public func write(_ index: ContextProfileIndex, aliasPaths: [String] = []) throws {
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
