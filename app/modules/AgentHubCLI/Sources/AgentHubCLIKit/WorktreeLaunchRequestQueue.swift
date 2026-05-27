import Foundation

public enum WorktreeLaunchProvider: String, Codable, CaseIterable, Equatable, Sendable {
  case claude = "Claude"
  case codex = "Codex"

  public init?(commandLineValue: String) {
    let normalized = commandLineValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "claude":
      self = .claude
    case "codex":
      self = .codex
    default:
      return nil
    }
  }

  public var commandLineValue: String {
    rawValue.lowercased()
  }
}

public struct WorktreeLaunchRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let createdAt: Date
  public let provider: WorktreeLaunchProvider
  public let repositoryPath: String
  public let worktreePath: String
  public let branchName: String
  public let prompt: String
  public let sourceProvider: WorktreeLaunchProvider?
  public let sourceSessionId: String?

  public init(
    id: String = UUID().uuidString,
    createdAt: Date = Date(),
    provider: WorktreeLaunchProvider,
    repositoryPath: String,
    worktreePath: String,
    branchName: String,
    prompt: String,
    sourceProvider: WorktreeLaunchProvider? = nil,
    sourceSessionId: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.provider = provider
    self.repositoryPath = repositoryPath
    self.worktreePath = worktreePath
    self.branchName = branchName
    self.prompt = prompt
    self.sourceProvider = sourceProvider
    self.sourceSessionId = sourceSessionId
  }
}

public struct QueuedWorktreeLaunchRequest: Equatable, Sendable {
  public let request: WorktreeLaunchRequest
  public let fileURL: URL

  public init(request: WorktreeLaunchRequest, fileURL: URL) {
    self.request = request
    self.fileURL = fileURL
  }
}

public enum WorktreeLaunchRequestQueueError: LocalizedError, Sendable {
  case missingProvider
  case missingPrompt

  public var errorDescription: String? {
    switch self {
    case .missingProvider:
      return "Missing launch provider. Pass --provider claude|codex or run inside an AgentHub embedded session."
    case .missingPrompt:
      return "Missing launch prompt. Pass --prompt when using --launch-session."
    }
  }
}

public struct WorktreeLaunchRequestQueue: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = WorktreeLaunchRequestQueue.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("cli-requests", isDirectory: true)
  }

  @discardableResult
  public func enqueue(_ request: WorktreeLaunchRequest) throws -> QueuedWorktreeLaunchRequest {
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

    return QueuedWorktreeLaunchRequest(request: request, fileURL: finalURL)
  }

  public func pendingRequests() throws -> [QueuedWorktreeLaunchRequest] {
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
              let request = try? decoder.decode(WorktreeLaunchRequest.self, from: data) else {
          return nil
        }
        return QueuedWorktreeLaunchRequest(request: request, fileURL: url)
      }
      .sorted {
        if $0.request.createdAt == $1.request.createdAt {
          return $0.request.id < $1.request.id
        }
        return $0.request.createdAt < $1.request.createdAt
      }
  }

  public func remove(_ queued: QueuedWorktreeLaunchRequest) throws {
    guard FileManager.default.fileExists(atPath: queued.fileURL.path) else { return }
    try FileManager.default.removeItem(at: queued.fileURL)
  }

  public func markFailed(_ queued: QueuedWorktreeLaunchRequest) throws {
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
