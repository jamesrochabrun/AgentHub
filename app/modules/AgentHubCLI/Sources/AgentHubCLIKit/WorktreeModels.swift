import Foundation

public enum WorktreeManagementError: LocalizedError, Sendable {
  case directoryAlreadyExists(String)
  case invalidBranchName(String)
  case gitCommandFailed(String)
  case fetchFailed(String)
  case worktreeAlreadyExists(String)
  case cancelled
  case timeout
  case notAGitRepository(String)

  public var errorDescription: String? {
    switch self {
    case .directoryAlreadyExists(let path):
      return "Directory already exists: \(path)"
    case .invalidBranchName(let name):
      return "Invalid branch name: \(name)"
    case .gitCommandFailed(let message):
      return "Git command failed: \(message)"
    case .fetchFailed(let message):
      return "Failed to fetch branches: \(message)"
    case .worktreeAlreadyExists(let branch):
      return "Worktree already exists for branch: \(branch)"
    case .cancelled:
      return "Git worktree creation was cancelled"
    case .timeout:
      return "Git command timed out"
    case .notAGitRepository(let path):
      return "Not a git repository: \(path)"
    }
  }
}

public struct WorktreeOperationID: Hashable, Sendable {
  public let value: UUID

  public init(_ value: UUID = UUID()) {
    self.value = value
  }
}

public struct WorktreeCancellationCleanupResult: Sendable, Equatable {
  public let removedWorktree: Bool
  public let removedBranch: Bool
  public let notes: [String]

  public init(
    removedWorktree: Bool,
    removedBranch: Bool,
    notes: [String] = []
  ) {
    self.removedWorktree = removedWorktree
    self.removedBranch = removedBranch
    self.notes = notes
  }
}

public struct WorktreeChangeSnapshot: Sendable, Equatable {
  public let stashRef: String?
  public let untrackedRelativePaths: [String]

  public init(stashRef: String?, untrackedRelativePaths: [String]) {
    self.stashRef = stashRef
    self.untrackedRelativePaths = untrackedRelativePaths
  }

  public var isEmpty: Bool {
    stashRef == nil && untrackedRelativePaths.isEmpty
  }
}

public struct WorktreeSparseCheckoutProfile: Codable, Equatable, Sendable {
  public static let agentSupportPaths = [
    ".agents",
    ".claude",
    ".claude-plugin",
    "scripts/git_hooks_support",
    "scripts/git_support"
  ]

  public let paths: [String]

  public init(paths: [String]) {
    var seen = Set<String>()
    self.paths = paths.compactMap { path in
      let normalized = Self.normalizedPath(path)
      guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
      return normalized
    }
  }

  public static func inferred(relativeStartPath: String) -> WorktreeSparseCheckoutProfile? {
    guard let ownerPath = ownerPath(for: relativeStartPath) else { return nil }
    return WorktreeSparseCheckoutProfile(paths: [ownerPath] + agentSupportPaths)
  }

  public static func ownerPath(for relativeStartPath: String) -> String? {
    let normalized = normalizedPath(relativeStartPath)
    guard !normalized.isEmpty else { return nil }
    return normalized
  }

  static func normalizedPath(_ path: String) -> String {
    path
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "/", omittingEmptySubsequences: true)
      .joined(separator: "/")
  }
}

public struct WorktreeCreationLocation: Sendable, Equatable {
  public let worktreePath: String
  public let launchPath: String
  public let isSparseCheckout: Bool
  public let sparseCheckoutPaths: [String]

  public init(
    worktreePath: String,
    launchPath: String,
    isSparseCheckout: Bool,
    sparseCheckoutPaths: [String] = []
  ) {
    self.worktreePath = worktreePath
    self.launchPath = launchPath
    self.isSparseCheckout = isSparseCheckout
    self.sparseCheckoutPaths = sparseCheckoutPaths
  }
}

public struct BranchInfo: Codable, Equatable, Identifiable, Sendable {
  public let name: String
  public let remote: String

  public init(name: String, remote: String) {
    self.name = name
    self.remote = remote
  }

  public var id: String { name }

  public var displayName: String {
    name.hasPrefix("\(remote)/") ? String(name.dropFirst(remote.count + 1)) : name
  }
}

public struct LocalBranchesResult: Sendable {
  public let branches: [BranchInfo]
  public let currentBranchName: String

  public init(branches: [BranchInfo], currentBranchName: String) {
    self.branches = branches
    self.currentBranchName = currentBranchName
  }
}

public struct WorktreeInfo: Codable, Equatable, Identifiable, Sendable {
  public let path: String
  public let branch: String?
  public let isWorktree: Bool
  public let mainRepoPath: String?

  public init(
    path: String,
    branch: String?,
    isWorktree: Bool,
    mainRepoPath: String?
  ) {
    self.path = path
    self.branch = branch
    self.isWorktree = isWorktree
    self.mainRepoPath = mainRepoPath
  }

  public var id: String { path }
}

public enum WorktreeCreationProgress: Equatable, Sendable, Codable {
  case idle
  case queued(message: String)
  case preparing(message: String)
  case updatingFiles(current: Int, total: Int)
  case completed(path: String)
  case cancelled(message: String)
  case failed(error: String)

  public var progressValue: Double {
    switch self {
    case .idle:
      return 0
    case .queued:
      return 0
    case .preparing:
      return 0.05
    case .updatingFiles(let current, let total):
      return total > 0 ? Double(current) / Double(total) : 0
    case .completed:
      return 1.0
    case .cancelled, .failed:
      return 0
    }
  }

  public var statusMessage: String {
    switch self {
    case .idle:
      return ""
    case .queued(let message):
      return message
    case .preparing(let message):
      return message
    case .updatingFiles(let current, let total):
      return "Updating files: \(current)/\(total)"
    case .completed(let path):
      return "Created: \((path as NSString).lastPathComponent)"
    case .cancelled(let message):
      return message
    case .failed(let error):
      return error
    }
  }

  public var isInProgress: Bool {
    switch self {
    case .queued, .preparing, .updatingFiles:
      return true
    case .idle, .completed, .cancelled, .failed:
      return false
    }
  }

  public var icon: String {
    switch self {
    case .idle:
      return "circle"
    case .queued:
      return "clock"
    case .preparing:
      return "arrow.triangle.branch"
    case .updatingFiles:
      return "doc.on.doc"
    case .completed:
      return "checkmark.circle.fill"
    case .cancelled:
      return "stop.circle.fill"
    case .failed:
      return "xmark.circle.fill"
    }
  }
}
