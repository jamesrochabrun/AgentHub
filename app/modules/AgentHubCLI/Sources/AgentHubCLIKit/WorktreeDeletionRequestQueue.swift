import Foundation

public struct WorktreeDeletionRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let createdAt: Date
  public let repositoryPath: String
  public let worktreePath: String
  public let branchName: String?
  public let force: Bool
  public let deleteAssociatedBranch: Bool
  public let removeFromDisk: Bool
  public let sourceProvider: WorktreeLaunchProvider?
  public let sourceSessionId: String?

  public init(
    id: String = UUID().uuidString,
    createdAt: Date = Date(),
    repositoryPath: String,
    worktreePath: String,
    branchName: String?,
    force: Bool = false,
    deleteAssociatedBranch: Bool = false,
    removeFromDisk: Bool = true,
    sourceProvider: WorktreeLaunchProvider? = nil,
    sourceSessionId: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.repositoryPath = repositoryPath
    self.worktreePath = worktreePath
    self.branchName = branchName
    self.force = force
    self.deleteAssociatedBranch = deleteAssociatedBranch
    self.removeFromDisk = removeFromDisk
    self.sourceProvider = sourceProvider
    self.sourceSessionId = sourceSessionId
  }
}

public struct QueuedWorktreeDeletionRequest: Equatable, Sendable {
  public let request: WorktreeDeletionRequest
  public let fileURL: URL

  public init(request: WorktreeDeletionRequest, fileURL: URL) {
    self.request = request
    self.fileURL = fileURL
  }
}

public struct WorktreeDeletionRequestQueue: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = WorktreeDeletionRequestQueue.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("worktree-deletion-requests", isDirectory: true)
  }

  @discardableResult
  public func enqueue(_ request: WorktreeDeletionRequest) throws -> QueuedWorktreeDeletionRequest {
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

    return QueuedWorktreeDeletionRequest(request: request, fileURL: finalURL)
  }

  public func pendingRequests() throws -> [QueuedWorktreeDeletionRequest] {
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
              let request = try? decoder.decode(WorktreeDeletionRequest.self, from: data) else {
          return nil
        }
        return QueuedWorktreeDeletionRequest(request: request, fileURL: url)
      }
      .sorted {
        if $0.request.createdAt == $1.request.createdAt {
          return $0.request.id < $1.request.id
        }
        return $0.request.createdAt < $1.request.createdAt
      }
  }

  public func remove(_ queued: QueuedWorktreeDeletionRequest) throws {
    guard FileManager.default.fileExists(atPath: queued.fileURL.path) else { return }
    try FileManager.default.removeItem(at: queued.fileURL)
  }

  public func markFailed(_ queued: QueuedWorktreeDeletionRequest) throws {
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
