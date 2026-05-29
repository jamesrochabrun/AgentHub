import Foundation

// MARK: - WorktreeProgressSnapshot

/// A point-in-time snapshot of a single worktree creation's progress, written
/// by the `agenthub` CLI (which performs the actual `git worktree add`) and
/// read by the app so it can surface live progress in the top bar.
///
/// Each in-flight creation owns one file `{operationID}.json` in the
/// `worktree-progress/` directory; the CLI overwrites it atomically on every
/// progress update until it reaches a terminal state.
public struct WorktreeProgressSnapshot: Codable, Sendable, Equatable, Identifiable {
  /// Stable identifier for the creation; also the file stem on disk.
  public let operationID: String
  public let branchName: String
  /// Main repository root the worktree is being created from (for display).
  public let repositoryPath: String
  public let provider: WorktreeLaunchProvider
  public let progress: WorktreeCreationProgress
  public let updatedAt: Date

  public init(
    operationID: String,
    branchName: String,
    repositoryPath: String,
    provider: WorktreeLaunchProvider,
    progress: WorktreeCreationProgress,
    updatedAt: Date = Date()
  ) {
    self.operationID = operationID
    self.branchName = branchName
    self.repositoryPath = repositoryPath
    self.provider = provider
    self.progress = progress
    self.updatedAt = updatedAt
  }

  public var id: String { operationID }
}

// MARK: - WorktreeProgressQueue

/// File-backed channel for worktree creation progress between the `agenthub`
/// CLI process and the app. Mirrors `WorktreeLaunchRequestQueue`'s conventions
/// (App Support directory, atomic temp-then-move writes) but lives in its OWN
/// directory — the launch monitor enumerates `*.json` in `cli-requests/`, so
/// progress files must never co-locate there or they'd be mis-parsed as launch
/// requests.
public struct WorktreeProgressQueue: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = WorktreeProgressQueue.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("worktree-progress", isDirectory: true)
  }

  /// Atomically writes (or overwrites) the snapshot for its operation.
  public func write(_ snapshot: WorktreeProgressSnapshot) throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)

    let finalURL = fileURL(for: snapshot.operationID)
    let temporaryURL = directoryURL.appendingPathComponent(".\(snapshot.operationID).tmp", isDirectory: false)

    try data.write(to: temporaryURL, options: [.atomic])
    if FileManager.default.fileExists(atPath: finalURL.path) {
      try FileManager.default.removeItem(at: finalURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
  }

  public func pendingSnapshots() throws -> [WorktreeProgressSnapshot] {
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
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WorktreeProgressSnapshot.self, from: data)
      }
      .sorted {
        if $0.updatedAt == $1.updatedAt {
          return $0.operationID < $1.operationID
        }
        return $0.updatedAt < $1.updatedAt
      }
  }

  public func remove(operationID: String) throws {
    let url = fileURL(for: operationID)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  /// Removes every progress file. Called at app launch so a snapshot left
  /// behind by a creation that finished while AgentHub was down can't be
  /// replayed as a fake in-flight operation on the next launch.
  public func wipeAll() throws {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
    let files = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    )
    for url in files {
      try? FileManager.default.removeItem(at: url)
    }
  }

  public func fileURL(for operationID: String) -> URL {
    directoryURL.appendingPathComponent("\(operationID).json", isDirectory: false)
  }
}
