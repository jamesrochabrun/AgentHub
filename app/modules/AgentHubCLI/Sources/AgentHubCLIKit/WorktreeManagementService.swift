import Foundation

public protocol WorktreeManagementServiceProtocol: Sendable {
  func findGitRoot(at path: String) async throws -> String
  func findMainRepositoryRoot(at path: String) async throws -> String
  func worktreesDirectory(at repoPath: String) async throws -> String
  func listWorktrees(at repoPath: String) async throws -> [WorktreeInfo]
  func getRemoteBranches(at repoPath: String) async throws -> [BranchInfo]
  func fetchAndGetRemoteBranches(at repoPath: String) async throws -> [BranchInfo]
  func getLocalBranches(at repoPath: String) async throws -> [BranchInfo]
  func getLocalBranchesWithCurrent(at repoPath: String) async throws -> LocalBranchesResult
  func createWorktree(at repoPath: String, branch: String, directoryName: String) async throws -> String
  func checkoutWorktree(at repoPath: String, branch: String, directoryName: String) async throws -> String
  func createWorktreeWithNewBranch(at repoPath: String, newBranchName: String, directoryName: String, startPoint: String?) async throws -> String
  func createWorktreeWithNewBranch(
    at repoPath: String,
    newBranchName: String,
    directoryName: String,
    startPoint: String?,
    operationID: WorktreeOperationID,
    onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void
  ) async throws -> String
  func cancelWorktreeCreation(_ operationID: WorktreeOperationID) async
  func cleanupCancelledWorktreeCreation(repoPath: String, newBranchName: String, directoryName: String) async -> WorktreeCancellationCleanupResult
  func captureStash(at repoPath: String) async throws -> String?
  func applyStash(_ ref: String, at path: String) async throws
  func captureWorkingTreeChanges(at repoPath: String) async throws -> WorktreeChangeSnapshot?
  func applyWorkingTreeChanges(_ snapshot: WorktreeChangeSnapshot, from sourcePath: String, to targetPath: String) async throws
  func getCurrentBranch(at repoPath: String) async throws -> String
  func getCurrentBranchFast(at repoPath: String) async throws -> String
  func hasUncommittedChanges(at repoPath: String) async throws -> Bool
  func removeWorktree(at worktreePath: String, force: Bool, deleteAssociatedBranch: Bool) async throws
  func removeWorktree(at worktreePath: String, relativeTo parentRepoPath: String, force: Bool, deleteAssociatedBranch: Bool) async throws
  func removeWorktreeForBranchOrPath(_ branchOrPath: String, repoPath: String, force: Bool) async throws
  func removeOrphanedWorktree(at worktreePath: String, parentRepoPath: String) async throws
}

public extension WorktreeManagementServiceProtocol {
  func createWorktreeWithNewBranch(at repoPath: String, newBranchName: String, directoryName: String) async throws -> String {
    try await createWorktreeWithNewBranch(
      at: repoPath,
      newBranchName: newBranchName,
      directoryName: directoryName,
      startPoint: nil
    )
  }

  func removeWorktree(at worktreePath: String, force: Bool = false) async throws {
    try await removeWorktree(
      at: worktreePath,
      force: force,
      deleteAssociatedBranch: false
    )
  }

  func removeWorktree(at worktreePath: String, relativeTo parentRepoPath: String, force: Bool = false) async throws {
    try await removeWorktree(
      at: worktreePath,
      relativeTo: parentRepoPath,
      force: force,
      deleteAssociatedBranch: false
    )
  }
}

public actor WorktreeManagementService: WorktreeManagementServiceProtocol {
  private static let gitCommandTimeout: TimeInterval = 10.0
  private static let gitWorktreeTimeout: TimeInterval = 300.0
  private static let updatingFilesPattern = #/Updating files:\s+\d+%\s+\((\d+)/(\d+)\)/#

  private var gitRootCache: [String: String] = [:]
  private var mainRootCache: [String: String] = [:]
  private var activeWorktreeProcesses: [WorktreeOperationID: Process] = [:]
  private var cancelledWorktreeOperations: Set<WorktreeOperationID> = []

  public init() {}

  public func findGitRoot(at path: String) async throws -> String {
    if let cached = gitRootCache[path] {
      return cached
    }
    let output = try await runGitCommand(["rev-parse", "--show-toplevel"], at: path)
    let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !root.isEmpty else {
      throw WorktreeManagementError.notAGitRepository(path)
    }
    gitRootCache[path] = root
    return root
  }

  public func findMainRepositoryRoot(at path: String) async throws -> String {
    if let cached = mainRootCache[path] {
      return cached
    }
    let output = try await runGitCommand(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: path)
    let commonDir = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commonDir.isEmpty else {
      throw WorktreeManagementError.notAGitRepository(path)
    }

    let root = (commonDir as NSString).deletingLastPathComponent
    mainRootCache[path] = root
    return root
  }

  public func worktreesDirectory(at repoPath: String) async throws -> String {
    let mainRoot = try await findMainRepositoryRoot(at: repoPath)
    return (mainRoot as NSString).appendingPathComponent(".worktrees")
  }

  public func listWorktrees(at repoPath: String) async throws -> [WorktreeInfo] {
    let mainRoot = try await findMainRepositoryRoot(at: repoPath)
    let output = try await runGitCommand(["worktree", "list", "--porcelain"], at: mainRoot)
    return parseWorktreeList(output)
  }

  public func getRemoteBranches(at repoPath: String) async throws -> [BranchInfo] {
    let gitRoot: String
    do {
      gitRoot = try await findGitRoot(at: repoPath)
    } catch {
      throw WorktreeManagementError.notAGitRepository(repoPath)
    }

    let output = try await runGitCommand(["branch", "-r"], at: gitRoot)
    return parseRemoteBranches(output)
  }

  public func fetchAndGetRemoteBranches(at repoPath: String) async throws -> [BranchInfo] {
    do {
      try await runGitCommand(["fetch", "--all"], at: repoPath)
    } catch {
      // Cached branches are still useful when offline or unauthenticated.
    }

    return try await getRemoteBranches(at: repoPath)
  }

  public func getLocalBranches(at repoPath: String) async throws -> [BranchInfo] {
    let gitRoot = try await findGitRoot(at: repoPath)
    let output = try await runGitCommand(["branch"], at: gitRoot)
    return parseLocalBranches(output)
  }

  public func getLocalBranchesWithCurrent(at repoPath: String) async throws -> LocalBranchesResult {
    let gitRoot = try await findGitRoot(at: repoPath)
    let output = try await runGitCommand(["branch"], at: gitRoot)
    return parseLocalBranchesWithCurrent(output)
  }

  public func createWorktree(
    at repoPath: String,
    branch: String,
    directoryName: String
  ) async throws -> String {
    let sourceRoot = try await findGitRoot(at: repoPath)
    let worktreePath = try await prepareWorktreePath(repoPath: repoPath, directoryName: directoryName)

    try await runGitCommand(
      ["worktree", "add", worktreePath, branch],
      at: sourceRoot,
      timeout: Self.gitWorktreeTimeout
    )

    return worktreePath
  }

  public func checkoutWorktree(
    at repoPath: String,
    branch: String,
    directoryName: String
  ) async throws -> String {
    if let existing = try await listWorktrees(at: repoPath)
      .first(where: { $0.branch == branch }) {
      return existing.path
    }

    return try await createWorktree(
      at: repoPath,
      branch: branch,
      directoryName: directoryName
    )
  }

  public func createWorktreeWithNewBranch(
    at repoPath: String,
    newBranchName: String,
    directoryName: String,
    startPoint: String? = nil
  ) async throws -> String {
    let sourceRoot = try await findGitRoot(at: repoPath)
    let worktreePath = try await prepareWorktreePath(repoPath: repoPath, directoryName: directoryName)

    var args = ["worktree", "add", "-b", newBranchName, worktreePath]
    if let startPoint {
      args.append(startPoint)
    }

    try await runGitCommand(args, at: sourceRoot, timeout: Self.gitWorktreeTimeout)
    return worktreePath
  }

  public func createWorktreeWithNewBranch(
    at repoPath: String,
    newBranchName: String,
    directoryName: String,
    startPoint: String? = nil,
    operationID: WorktreeOperationID,
    onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void
  ) async throws -> String {
    if cancelledWorktreeOperations.contains(operationID) {
      await onProgress(.cancelled(message: "Cancelled before worktree creation began"))
      cancelledWorktreeOperations.remove(operationID)
      throw WorktreeManagementError.cancelled
    }

    await onProgress(.preparing(message: "Preparing worktree..."))

    let sourceRoot = try await findGitRoot(at: repoPath)
    let worktreePath = try await prepareWorktreePath(repoPath: repoPath, directoryName: directoryName)

    var args = ["worktree", "add", "-b", newBranchName, worktreePath]
    if let startPoint {
      args.append(startPoint)
    }

    try await runGitCommandWithProgress(
      args,
      at: sourceRoot,
      timeout: Self.gitWorktreeTimeout,
      operationID: operationID,
      onProgress: onProgress
    )

    await onProgress(.completed(path: worktreePath))
    return worktreePath
  }

  public func cancelWorktreeCreation(_ operationID: WorktreeOperationID) async {
    cancelledWorktreeOperations.insert(operationID)
    if let process = activeWorktreeProcesses[operationID] {
      Self.terminateIfRunning(process)
    }
  }

  public func cleanupCancelledWorktreeCreation(
    repoPath: String,
    newBranchName: String,
    directoryName: String
  ) async -> WorktreeCancellationCleanupResult {
    var notes: [String] = []
    var removedWorktree = false
    var removedBranch = false

    do {
      let sourceRoot = try await findGitRoot(at: repoPath)
      let mainRoot = try await findMainRepositoryRoot(at: repoPath)
      let worktreesDirectory = (mainRoot as NSString).appendingPathComponent(".worktrees")
      let worktreePath = (worktreesDirectory as NSString).appendingPathComponent(directoryName)

      let fileManager = FileManager.default

      if fileManager.fileExists(atPath: worktreePath) {
        if let orphaned = checkIfOrphaned(at: worktreePath),
           orphaned.isOrphaned,
           let parentRepoPath = orphaned.parentRepoPath {
          do {
            try await removeOrphanedWorktree(at: worktreePath, parentRepoPath: parentRepoPath)
            removedWorktree = true
            notes.append("Removed orphaned worktree directory")
          } catch {
            notes.append("Failed to remove orphaned worktree: \(error.localizedDescription)")
          }
        } else {
          do {
            try await removeWorktree(
              at: worktreePath,
              relativeTo: mainRoot,
              force: true,
              deleteAssociatedBranch: false
            )
            removedWorktree = true
            notes.append("Removed git worktree")
          } catch {
            notes.append("git worktree remove failed: \(error.localizedDescription)")
            do {
              try fileManager.removeItem(atPath: worktreePath)
              removedWorktree = true
              notes.append("Removed worktree directory directly")
            } catch {
              notes.append("Direct directory cleanup failed: \(error.localizedDescription)")
            }
          }
        }
      }

      do {
        if try await branchExists(newBranchName, at: sourceRoot) {
          try await runGitCommand(["branch", "-D", newBranchName], at: sourceRoot)
          removedBranch = true
          notes.append("Removed generated branch")
        }
      } catch {
        notes.append("Branch cleanup failed: \(error.localizedDescription)")
      }

      do {
        try await runGitCommand(["worktree", "prune"], at: mainRoot)
      } catch {
        notes.append("Worktree prune failed: \(error.localizedDescription)")
      }
    } catch {
      notes.append("Cleanup setup failed: \(error.localizedDescription)")
    }

    return WorktreeCancellationCleanupResult(
      removedWorktree: removedWorktree,
      removedBranch: removedBranch,
      notes: notes
    )
  }

  public func captureStash(at repoPath: String) async throws -> String? {
    let gitRoot = try await findGitRoot(at: repoPath)
    let output = try await runGitCommand(["stash", "create"], at: gitRoot)
    let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return sha.isEmpty ? nil : sha
  }

  public func applyStash(_ ref: String, at path: String) async throws {
    let gitRoot = try await findGitRoot(at: path)
    try await runGitCommand(["stash", "apply", ref], at: gitRoot, timeout: 60)
  }

  public func captureWorkingTreeChanges(at repoPath: String) async throws -> WorktreeChangeSnapshot? {
    let gitRoot = try await findGitRoot(at: repoPath)
    let stashRef = try await captureStash(at: gitRoot)
    let untrackedOutput = try await runGitCommand(
      ["ls-files", "--others", "--exclude-standard", "-z"],
      at: gitRoot
    )
    let untrackedPaths = untrackedOutput
      .components(separatedBy: "\0")
      .filter { !$0.isEmpty }

    let snapshot = WorktreeChangeSnapshot(
      stashRef: stashRef,
      untrackedRelativePaths: untrackedPaths
    )
    return snapshot.isEmpty ? nil : snapshot
  }

  public func applyWorkingTreeChanges(
    _ snapshot: WorktreeChangeSnapshot,
    from sourcePath: String,
    to targetPath: String
  ) async throws {
    if let stashRef = snapshot.stashRef {
      try await applyStash(stashRef, at: targetPath)
    }

    guard !snapshot.untrackedRelativePaths.isEmpty else { return }

    let sourceRoot = try await findGitRoot(at: sourcePath)
    let targetRoot = try await findGitRoot(at: targetPath)
    try copyUntrackedFiles(
      snapshot.untrackedRelativePaths,
      from: sourceRoot,
      to: targetRoot
    )
  }

  public func getCurrentBranch(at repoPath: String) async throws -> String {
    let output = try await runGitCommand(["branch", "--show-current"], at: repoPath)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func getCurrentBranchFast(at repoPath: String) async throws -> String {
    let gitPath = (repoPath as NSString).appendingPathComponent(".git")

    var headFilePath: String
    var isDirectory: ObjCBool = false

    if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
      if isDirectory.boolValue {
        headFilePath = (gitPath as NSString).appendingPathComponent("HEAD")
      } else {
        guard let contents = try? String(contentsOfFile: gitPath, encoding: .utf8),
              let gitdirLine = contents.components(separatedBy: .newlines).first(where: { $0.hasPrefix("gitdir:") }) else {
          return try await getCurrentBranch(at: repoPath)
        }
        let gitdirPath = gitdirLine
          .replacingOccurrences(of: "gitdir:", with: "")
          .trimmingCharacters(in: .whitespaces)

        let resolvedGitdir: String
        if gitdirPath.hasPrefix("/") {
          resolvedGitdir = gitdirPath
        } else {
          resolvedGitdir = (repoPath as NSString).appendingPathComponent(gitdirPath)
        }
        headFilePath = (resolvedGitdir as NSString).appendingPathComponent("HEAD")
      }
    } else {
      return try await getCurrentBranch(at: repoPath)
    }

    guard let headContents = try? String(contentsOfFile: headFilePath, encoding: .utf8) else {
      return try await getCurrentBranch(at: repoPath)
    }

    let head = headContents.trimmingCharacters(in: .whitespacesAndNewlines)
    if head.hasPrefix("ref: refs/heads/") {
      return String(head.dropFirst("ref: refs/heads/".count))
    }

    return ""
  }

  public func hasUncommittedChanges(at repoPath: String) async throws -> Bool {
    let output = try await runGitCommand(["status", "--porcelain"], at: repoPath)
    return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public func removeWorktree(
    at worktreePath: String,
    force: Bool = false,
    deleteAssociatedBranch: Bool = false
  ) async throws {
    let parentRepoPath = try await findMainRepositoryRoot(at: worktreePath)
    try await removeWorktree(
      at: worktreePath,
      relativeTo: parentRepoPath,
      force: force,
      deleteAssociatedBranch: deleteAssociatedBranch
    )
  }

  public func removeWorktree(
    at worktreePath: String,
    relativeTo parentRepoPath: String,
    force: Bool = false,
    deleteAssociatedBranch: Bool = false
  ) async throws {
    guard FileManager.default.fileExists(atPath: worktreePath) else {
      try runGitCommandSync(["worktree", "prune"], at: parentRepoPath)
      return
    }

    let branchToDelete: String?
    if deleteAssociatedBranch {
      branchToDelete = try? await getCurrentBranchFast(at: worktreePath)
    } else {
      branchToDelete = nil
    }

    var args = ["worktree", "remove"]
    if force {
      args += ["--force", "--force"]
    }
    args.append(worktreePath)
    try runGitCommandSync(args, at: parentRepoPath)

    if let branchToDelete, !branchToDelete.isEmpty {
      try runGitCommandSync(["branch", force ? "-D" : "-d", branchToDelete], at: parentRepoPath)
    }
  }

  public func removeWorktreeForBranchOrPath(
    _ branchOrPath: String,
    repoPath: String,
    force: Bool = false
  ) async throws {
    let targetPath: String
    if branchOrPath.hasPrefix("/") || FileManager.default.fileExists(atPath: branchOrPath) {
      targetPath = URL(fileURLWithPath: branchOrPath).standardizedFileURL.path
    } else if let matching = try await listWorktrees(at: repoPath)
      .first(where: { $0.branch == branchOrPath }) {
      targetPath = matching.path
    } else {
      let mainRoot = try await findMainRepositoryRoot(at: repoPath)
      let directoryName = WorktreeNaming.worktreeDirectoryName(for: branchOrPath)
      let worktreesDirectory = (mainRoot as NSString).appendingPathComponent(".worktrees")
      targetPath = (worktreesDirectory as NSString).appendingPathComponent(directoryName)
    }

    let mainRoot = try await findMainRepositoryRoot(at: repoPath)
    try await removeWorktree(
      at: targetPath,
      relativeTo: mainRoot,
      force: force,
      deleteAssociatedBranch: true
    )
  }

  public nonisolated func checkIfOrphaned(at worktreePath: String) -> (isOrphaned: Bool, parentRepoPath: String?)? {
    let gitFile = (worktreePath as NSString).appendingPathComponent(".git")

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gitFile, isDirectory: &isDirectory),
          !isDirectory.boolValue else {
      return nil
    }

    guard let contents = try? String(contentsOfFile: gitFile, encoding: .utf8),
          let gitdirLine = contents.components(separatedBy: .newlines).first(where: { $0.hasPrefix("gitdir:") }) else {
      return nil
    }

    let gitdirPath = gitdirLine
      .replacingOccurrences(of: "gitdir:", with: "")
      .trimmingCharacters(in: .whitespaces)

    if let range = gitdirPath.range(of: "/.git/worktrees/") {
      let parentRepoPath = String(gitdirPath[..<range.lowerBound])
      let metadataExists = FileManager.default.fileExists(atPath: gitdirPath)
      return (isOrphaned: !metadataExists, parentRepoPath: parentRepoPath)
    }

    return nil
  }

  public func removeOrphanedWorktree(at worktreePath: String, parentRepoPath: String) async throws {
    try await runGitCommand(["worktree", "prune"], at: parentRepoPath)

    guard FileManager.default.fileExists(atPath: worktreePath) else {
      return
    }
    try FileManager.default.removeItem(atPath: worktreePath)
  }
}

private extension WorktreeManagementService {
  func prepareWorktreePath(repoPath: String, directoryName: String) async throws -> String {
    let mainRoot = try await findMainRepositoryRoot(at: repoPath)
    try ensureWorktreesDirectory(mainRoot: mainRoot, repoPath: repoPath)

    let worktreesDirectory = (mainRoot as NSString).appendingPathComponent(".worktrees")
    let worktreePath = (worktreesDirectory as NSString).appendingPathComponent(directoryName)

    if FileManager.default.fileExists(atPath: worktreePath) {
      throw WorktreeManagementError.directoryAlreadyExists(worktreePath)
    }

    return worktreePath
  }

  func copyUntrackedFiles(
    _ relativePaths: [String],
    from sourceRoot: String,
    to targetRoot: String
  ) throws {
    for relativePath in relativePaths {
      let sourcePath = try resolvedPath(root: sourceRoot, relativePath: relativePath)
      let targetPath = try resolvedPath(root: targetRoot, relativePath: relativePath)

      guard FileManager.default.fileExists(atPath: sourcePath) else { continue }

      let targetDirectory = (targetPath as NSString).deletingLastPathComponent
      try FileManager.default.createDirectory(
        atPath: targetDirectory,
        withIntermediateDirectories: true
      )

      if FileManager.default.fileExists(atPath: targetPath) {
        try FileManager.default.removeItem(atPath: targetPath)
      }

      try FileManager.default.copyItem(atPath: sourcePath, toPath: targetPath)
    }
  }

  func resolvedPath(root: String, relativePath: String) throws -> String {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.hasPrefix("/"),
          !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
      throw WorktreeManagementError.gitCommandFailed("Invalid relative path: \(relativePath)")
    }

    return (root as NSString).appendingPathComponent(relativePath)
  }

  func ensureWorktreesDirectory(mainRoot: String, repoPath: String) throws {
    let worktreesDirectory = (mainRoot as NSString).appendingPathComponent(".worktrees")
    try FileManager.default.createDirectory(
      atPath: worktreesDirectory,
      withIntermediateDirectories: true
    )

    let commonDirOutput = try runGitCommandSync(
      ["rev-parse", "--path-format=absolute", "--git-common-dir"],
      at: repoPath
    )
    let commonDir = commonDirOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commonDir.isEmpty else { return }

    let infoDirectory = (commonDir as NSString).appendingPathComponent("info")
    try FileManager.default.createDirectory(atPath: infoDirectory, withIntermediateDirectories: true)
    let excludeFile = (infoDirectory as NSString).appendingPathComponent("exclude")

    let existing = (try? String(contentsOfFile: excludeFile, encoding: .utf8)) ?? ""
    let lines = existing.components(separatedBy: .newlines)
    guard !lines.contains(".worktrees/") else { return }

    let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
    let updated = existing + prefix + ".worktrees/\n"
    try updated.write(toFile: excludeFile, atomically: true, encoding: .utf8)
  }

  func branchExists(_ branchName: String, at repoPath: String) async throws -> Bool {
    do {
      try await runGitCommand(
        ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
        at: repoPath
      )
      return true
    } catch WorktreeManagementError.gitCommandFailed(let message) where message.isEmpty {
      return false
    }
  }

  func parseRemoteBranches(_ output: String) -> [BranchInfo] {
    output.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.contains("->") }
      .compactMap { line -> BranchInfo? in
        let parts = line.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return BranchInfo(name: line, remote: String(parts[0]))
      }
      .sorted { $0.displayName < $1.displayName }
  }

  func parseLocalBranches(_ output: String) -> [BranchInfo] {
    output.components(separatedBy: .newlines)
      .map { line -> String in
        var cleaned = line.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("*") || cleaned.hasPrefix("+") {
          cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return cleaned
      }
      .filter { !$0.isEmpty && !$0.hasPrefix("(") }
      .map { BranchInfo(name: $0, remote: "local") }
      .sorted { $0.displayName < $1.displayName }
  }

  func parseLocalBranchesWithCurrent(_ output: String) -> LocalBranchesResult {
    let lines = output.components(separatedBy: .newlines)
    var currentBranchName = ""
    var branches: [BranchInfo] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }

      if trimmed.hasPrefix("*") {
        let branchPart = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        if !branchPart.hasPrefix("(") {
          currentBranchName = branchPart
          branches.append(BranchInfo(name: branchPart, remote: "local"))
        }
      } else if trimmed.hasPrefix("+") {
        let branchPart = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        branches.append(BranchInfo(name: branchPart, remote: "local"))
      } else {
        branches.append(BranchInfo(name: trimmed, remote: "local"))
      }
    }

    branches.sort { $0.displayName < $1.displayName }
    return LocalBranchesResult(branches: branches, currentBranchName: currentBranchName)
  }

  func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
    var worktrees: [WorktreeInfo] = []
    var currentPath: String?
    var currentBranch: String?
    var isFirstWorktree = true
    var actualMainRepoPath: String?

    func appendCurrent() {
      guard let path = currentPath else { return }
      let isMainRepo = isFirstWorktree
      if isMainRepo {
        actualMainRepoPath = path
      }
      worktrees.append(WorktreeInfo(
        path: path,
        branch: currentBranch,
        isWorktree: !isMainRepo,
        mainRepoPath: isMainRepo ? nil : actualMainRepoPath
      ))
      isFirstWorktree = false
    }

    for line in output.components(separatedBy: .newlines) {
      if line.hasPrefix("worktree ") {
        appendCurrent()
        currentPath = String(line.dropFirst("worktree ".count))
        currentBranch = nil
      } else if line.hasPrefix("branch refs/heads/") {
        currentBranch = String(line.dropFirst("branch refs/heads/".count))
      }
    }

    appendCurrent()
    return worktrees
  }

  @discardableResult
  func runGitCommand(
    _ arguments: [String],
    at path: String,
    timeout: TimeInterval = gitCommandTimeout
  ) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    process.environment = environment

    let inputPipe = Pipe()
    process.standardInput = inputPipe

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      try inputPipe.fileHandleForWriting.close()
    } catch {
      throw WorktreeManagementError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
    }

    let didTimeout = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          DispatchQueue.global().async {
            process.waitUntilExit()
            continuation.resume(returning: false)
          }
        }
      }

      group.addTask {
        do {
          try await Task.sleep(for: .seconds(timeout))
          if process.isRunning {
            process.terminate()
          }
          return true
        } catch {
          return false
        }
      }

      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

    if didTimeout {
      throw WorktreeManagementError.timeout
    }

    if process.terminationStatus != 0 {
      throw WorktreeManagementError.gitCommandFailed(
        errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    return output
  }

  @discardableResult
  func runGitCommandSync(_ arguments: [String], at path: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    process.environment = environment

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    try inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
      throw WorktreeManagementError.gitCommandFailed(
        errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    return output
  }

  @discardableResult
  func runGitCommandWithProgress(
    _ arguments: [String],
    at path: String,
    timeout: TimeInterval,
    operationID: WorktreeOperationID,
    onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void
  ) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    process.environment = environment

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let stderrCollector = GitStderrCollector()
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty,
            let chunk = String(data: data, encoding: .utf8) else {
        return
      }

      let lines = stderrCollector.append(chunk)
      for line in lines {
        if let progress = Self.parseUpdatingFilesProgress(from: line) {
          Task {
            await onProgress(.updatingFiles(current: progress.current, total: progress.total))
          }
        } else if line.contains("Preparing worktree") {
          Task {
            await onProgress(.preparing(message: "Preparing worktree..."))
          }
        }
      }
    }

    activeWorktreeProcesses[operationID] = process
    defer {
      activeWorktreeProcesses.removeValue(forKey: operationID)
    }

    let (exitCode, didTimeout) = try await withTaskCancellationHandler {
      if cancelledWorktreeOperations.contains(operationID) {
        throw WorktreeManagementError.cancelled
      }

      do {
        try process.run()
        try inputPipe.fileHandleForWriting.close()
      } catch {
        throw WorktreeManagementError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
      }

      return await withTaskGroup(of: (Int32, Bool).self) { group in
        group.addTask {
          let exitCode = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async {
              process.waitUntilExit()
              continuation.resume(returning: process.terminationStatus)
            }
          }
          return (exitCode, false)
        }

        group.addTask {
          do {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning {
              process.terminate()
            }
            return (Int32(-1), true)
          } catch {
            return (Int32(-1), false)
          }
        }

        let result = await group.next() ?? (Int32(-1), false)
        group.cancelAll()
        return result
      }
    } onCancel: {
      Self.terminateIfRunning(process)
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    errorPipe.fileHandleForReading.readabilityHandler = nil
    let remainingErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    if let remainingError = String(data: remainingErrorData, encoding: .utf8),
       !remainingError.isEmpty {
      _ = stderrCollector.append(remainingError)
    }

    let output = String(data: outputData, encoding: .utf8) ?? ""
    let wasCancelled = cancelledWorktreeOperations.remove(operationID) != nil || Task.isCancelled

    if didTimeout {
      throw WorktreeManagementError.timeout
    }

    if wasCancelled {
      throw WorktreeManagementError.cancelled
    }

    if exitCode != 0 {
      let errorOutput = stderrCollector.getAll()
      throw WorktreeManagementError.gitCommandFailed(
        errorOutput.isEmpty ? "Git command failed with exit code \(exitCode)" : errorOutput
      )
    }

    return output
  }

  static func parseUpdatingFilesProgress(from line: String) -> (current: Int, total: Int)? {
    guard let match = line.firstMatch(of: updatingFilesPattern),
          let current = Int(match.1),
          let total = Int(match.2) else {
      return nil
    }
    return (current, total)
  }

  static func terminateIfRunning(_ process: Process) {
    if process.isRunning {
      process.terminate()
    }
  }
}

private final class GitStderrCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  private var partialLine = ""

  func append(_ chunk: String) -> [String] {
    lock.lock()
    defer { lock.unlock() }

    partialLine += chunk
    var parts = partialLine.components(separatedBy: .newlines)
    partialLine = parts.popLast() ?? ""
    lines.append(contentsOf: parts)
    return parts
  }

  func getAll() -> String {
    lock.lock()
    defer { lock.unlock() }

    var output = lines
    if !partialLine.isEmpty {
      output.append(partialLine)
    }
    return output.joined(separator: "\n")
  }
}
