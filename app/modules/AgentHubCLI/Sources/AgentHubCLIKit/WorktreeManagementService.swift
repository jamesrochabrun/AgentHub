import Foundation

public protocol WorktreeManagementServiceProtocol: Sendable {
  func findGitRoot(at path: String) async throws -> String
  func findMainRepositoryRoot(at path: String) async throws -> String
  func worktreesDirectory(at repoPath: String) async throws -> String
  func listWorktrees(at repoPath: String) async throws -> [WorktreeInfo]
  func getRemoteBranches(at repoPath: String) async throws -> [BranchInfo]
  func fetchAndGetRemoteBranches(at repoPath: String) async throws -> [BranchInfo]
  func fetchAndGetDefaultRemoteBaseBranch(at repoPath: String) async throws -> BranchInfo?
  func getLocalBranches(at repoPath: String) async throws -> [BranchInfo]
  func getLocalBranchesWithCurrent(at repoPath: String) async throws -> LocalBranchesResult
  func createWorktree(at repoPath: String, branch: String, directoryName: String) async throws -> String
  func checkoutWorktree(at repoPath: String, branch: String, directoryName: String) async throws -> String
  func createWorktreeWithNewBranch(at repoPath: String, newBranchName: String, directoryName: String, startPoint: String?) async throws -> String
  func createAgentWorktreeWithNewBranch(
    at repoPath: String,
    startPath: String?,
    newBranchName: String,
    directoryName: String,
    startPoint: String?,
    sparseProfile: WorktreeSparseCheckoutProfile?,
    fullCheckout: Bool
  ) async throws -> WorktreeCreationLocation
  func launchPath(forStartPath startPath: String?, repoPath: String, worktreePath: String) async throws -> String
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
  private static let creationQueue = WorktreeCreationQueue(
    maxConcurrentGlobally: 2,
    maxConcurrentPerRepository: 1
  )
  private static let updatingFilesPattern = #/Updating files:\s+\d+%\s+\((\d+)/(\d+)\)/#
  private static let sparseProjectMarkerFileNames: Set<String> = [
    "Package.swift",
    "Project.swift",
    "Workspace.swift",
    "Podfile",
    "package.json",
    "pnpm-workspace.yaml",
    "Cargo.toml",
    "go.mod",
    "pyproject.toml",
    "requirements.txt",
    "Gemfile",
    "Makefile",
    "CMakeLists.txt"
  ]
  private static let sparseGradleRootMarkerFileNames: Set<String> = [
    "settings.gradle",
    "settings.gradle.kts",
    "gradlew"
  ]
  private static let sparseGradleBuildMarkerFileNames: Set<String> = [
    "build.gradle",
    "build.gradle.kts"
  ]
  private static let sparseProjectMarkerSuffixes = [
    ".xcodeproj",
    ".xcworkspace"
  ]
  private static let topLevelGradleSupportPath = "gradle"

  private struct SparseCheckoutInference: Sendable {
    let ownerPath: String
    let paths: [String]
  }

  private struct SparseProjectMarkerMatch: Sendable {
    let ownerPath: String
    let includesGradleSupport: Bool
  }

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
    return siblingWorktreeDirectory(mainRoot: mainRoot)
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

  public func fetchAndGetDefaultRemoteBaseBranch(at repoPath: String) async throws -> BranchInfo? {
    let gitRoot: String
    do {
      gitRoot = try await findGitRoot(at: repoPath)
    } catch {
      throw WorktreeManagementError.notAGitRepository(repoPath)
    }

    do {
      try await runGitCommand(["fetch", "--all"], at: gitRoot)
    } catch {
      // Keep the picker useful offline: fall back to the latest cached remote refs.
    }

    let output = try await runGitCommand(["branch", "-r"], at: gitRoot)
    return defaultRemoteBaseBranch(from: output)
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
    let repoKey = try await findMainRepositoryRoot(at: repoPath)
    return try await Self.creationQueue.withPermit(repoKey: repoKey) { [self] in
      let sourceRoot = try await findGitRoot(at: repoPath)
      let worktreePath = try await prepareWorktreePath(repoPath: repoPath, directoryName: directoryName)

      try await runGitCommand(
        ["worktree", "add", worktreePath, branch],
        at: sourceRoot,
        timeout: Self.gitWorktreeTimeout
      )

      return await resolveCreatedWorktreePath(
        requestedPath: worktreePath,
        branch: branch,
        repoPath: sourceRoot
      )
    }
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
    let repoKey = try await findMainRepositoryRoot(at: repoPath)
    return try await Self.creationQueue.withPermit(repoKey: repoKey) { [self] in
      let sourceRoot = try await findGitRoot(at: repoPath)
      let worktreePath = try await prepareWorktreePath(repoPath: repoPath, directoryName: directoryName)

      var args = ["worktree", "add", "-b", newBranchName, worktreePath]
      if let startPoint {
        args.append(startPoint)
      }

      try await runGitCommand(args, at: sourceRoot, timeout: Self.gitWorktreeTimeout)
      return await resolveCreatedWorktreePath(
        requestedPath: worktreePath,
        branch: newBranchName,
        repoPath: sourceRoot
      )
    }
  }

  public func createAgentWorktreeWithNewBranch(
    at repoPath: String,
    startPath: String?,
    newBranchName: String,
    directoryName: String,
    startPoint: String? = nil,
    sparseProfile: WorktreeSparseCheckoutProfile?,
    fullCheckout: Bool
  ) async throws -> WorktreeCreationLocation {
    let repoKey = try await findMainRepositoryRoot(at: repoPath)
    return try await Self.creationQueue.withPermit(repoKey: repoKey) { [self] in
      let sourceRoot = try await findGitRoot(at: repoPath)
      let worktreePath = try await prepareWorktreePath(repoPath: repoPath, directoryName: directoryName)

      if fullCheckout {
        return try await createFullAgentWorktree(
          sourceRoot: sourceRoot,
          worktreePath: worktreePath,
          newBranchName: newBranchName,
          startPoint: startPoint,
          repoPath: repoPath,
          startPath: startPath
        )
      }

      let relativeStartPath = try relativeStartPath(
        sourceRoot: sourceRoot,
        startPath: startPath ?? repoPath
      )
      let treeish = startPoint ?? "HEAD"
      let sparsePaths = try await resolvedSparseCheckoutPaths(
        profile: sparseProfile,
        relativeStartPath: relativeStartPath,
        treeish: treeish,
        sourceRoot: sourceRoot
      )

      if sparsePaths.isEmpty, sparseProfile == nil {
        return try await createFullAgentWorktree(
          sourceRoot: sourceRoot,
          worktreePath: worktreePath,
          newBranchName: newBranchName,
          startPoint: startPoint,
          repoPath: repoPath,
          startPath: startPath
        )
      }

      guard !sparsePaths.isEmpty else {
        throw WorktreeManagementError.gitCommandFailed(
          "Sparse checkout profile did not match any tracked paths for \(startPath ?? repoPath). Pass tracked sparse paths or request a full checkout."
        )
      }

      var args = ["worktree", "add", "--no-checkout", "-b", newBranchName, worktreePath]
      if let startPoint {
        args.append(startPoint)
      }

      try await runGitCommand(args, at: sourceRoot, timeout: Self.gitWorktreeTimeout)
      try await configureSparseCheckout(paths: sparsePaths, at: worktreePath)
      try await runGitCommand(["checkout", "HEAD"], at: worktreePath, timeout: Self.gitWorktreeTimeout)

      let resolvedPath = await resolveCreatedWorktreePath(
        requestedPath: worktreePath,
        branch: newBranchName,
        repoPath: sourceRoot
      )
      return WorktreeCreationLocation(
        worktreePath: resolvedPath,
        launchPath: try launchPath(
          sourceRoot: sourceRoot,
          startPath: startPath ?? repoPath,
          worktreePath: resolvedPath
        ),
        isSparseCheckout: true,
        sparseCheckoutPaths: sparsePaths
      )
    }
  }

  private func createFullAgentWorktree(
    sourceRoot: String,
    worktreePath: String,
    newBranchName: String,
    startPoint: String?,
    repoPath: String,
    startPath: String?
  ) async throws -> WorktreeCreationLocation {
    var args = ["worktree", "add", "-b", newBranchName, worktreePath]
    if let startPoint {
      args.append(startPoint)
    }

    try await runGitCommand(args, at: sourceRoot, timeout: Self.gitWorktreeTimeout)
    let resolvedPath = await resolveCreatedWorktreePath(
      requestedPath: worktreePath,
      branch: newBranchName,
      repoPath: sourceRoot
    )
    return WorktreeCreationLocation(
      worktreePath: resolvedPath,
      launchPath: try launchPath(
        sourceRoot: sourceRoot,
        startPath: startPath ?? repoPath,
        worktreePath: resolvedPath
      ),
      isSparseCheckout: false
    )
  }

  public func launchPath(forStartPath startPath: String?, repoPath: String, worktreePath: String) async throws -> String {
    let sourceRoot = try await findGitRoot(at: repoPath)
    return try launchPath(
      sourceRoot: sourceRoot,
      startPath: startPath ?? repoPath,
      worktreePath: worktreePath
    )
  }

  public func createWorktreeWithNewBranch(
    at repoPath: String,
    newBranchName: String,
    directoryName: String,
    startPoint: String? = nil,
    operationID: WorktreeOperationID,
    onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void
  ) async throws -> String {
    if consumeCancellation(for: operationID) {
      await onProgress(.cancelled(message: "Cancelled before worktree creation began"))
      throw WorktreeManagementError.cancelled
    }

    let repoKey = try await findMainRepositoryRoot(at: repoPath)
    return try await Self.creationQueue.withPermit(
      repoKey: repoKey,
      onQueued: {
        await onProgress(.queued(message: "Queued behind another worktree for this repository"))
      }
    ) { [self] in
      if await consumeCancellation(for: operationID) {
        await onProgress(.cancelled(message: "Cancelled before worktree creation began"))
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

      let resolvedWorktreePath = await resolveCreatedWorktreePath(
        requestedPath: worktreePath,
        branch: newBranchName,
        repoPath: sourceRoot
      )
      await onProgress(.completed(path: resolvedWorktreePath))
      return resolvedWorktreePath
    }
  }

  public func cancelWorktreeCreation(_ operationID: WorktreeOperationID) async {
    cancelledWorktreeOperations.insert(operationID)
    if let process = activeWorktreeProcesses[operationID] {
      Self.terminateIfRunning(process)
    }
  }

  private func consumeCancellation(for operationID: WorktreeOperationID) -> Bool {
    guard cancelledWorktreeOperations.contains(operationID) else { return false }
    cancelledWorktreeOperations.remove(operationID)
    return true
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
      let worktreePath = siblingWorktreePath(mainRoot: mainRoot, directoryName: directoryName)

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
    let mainRepoPath = try await findMainRepositoryRoot(at: parentRepoPath)
    guard FileManager.default.fileExists(atPath: worktreePath) else {
      try await pruneStaleWorktreeMetadata(for: worktreePath, parentRepoPath: mainRepoPath)
      return
    }

    let registeredInfo = try? await registeredWorktree(at: worktreePath, relativeTo: mainRepoPath)
    if let registeredInfo, !registeredInfo.isWorktree {
      throw WorktreeManagementError.gitCommandFailed("Refusing to delete the main worktree: \(worktreePath)")
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
    // Removing a worktree deletes its files, which can be slow on a large tree —
    // use the longer worktree timeout so a healthy removal isn't cut short, while
    // still bounding a genuine git hang (the old sync path waited forever).
    do {
      try await runGitCommand(args, at: mainRepoPath, timeout: Self.gitWorktreeTimeout)
    } catch let gitError {
      guard force else {
        throw gitError
      }
      do {
        try Self.validateFilesystemForceRemoval(
          of: worktreePath,
          mainRepoPath: mainRepoPath,
          isRegisteredLinkedWorktree: registeredInfo?.isWorktree == true
        )
      } catch {
        throw gitError
      }
      try await forceRemoveWorktreeDirectory(worktreePath, parentRepoPath: mainRepoPath)
    }

    if FileManager.default.fileExists(atPath: worktreePath) {
      guard force else {
        throw WorktreeManagementError.gitCommandFailed(
          "Git reported success but the worktree directory still exists: \(worktreePath)"
        )
      }
      try Self.validateFilesystemForceRemoval(
        of: worktreePath,
        mainRepoPath: mainRepoPath,
        isRegisteredLinkedWorktree: registeredInfo?.isWorktree == true
      )
      try await forceRemoveWorktreeDirectory(worktreePath, parentRepoPath: mainRepoPath)
    }

    if let stillRegistered = try await registeredWorktree(at: worktreePath, relativeTo: mainRepoPath),
       stillRegistered.isWorktree {
      try await pruneStaleWorktreeMetadata(for: worktreePath, parentRepoPath: mainRepoPath)
    }

    if let branchToDelete, !branchToDelete.isEmpty {
      try await runGitCommand(["branch", force ? "-D" : "-d", branchToDelete], at: mainRepoPath)
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
      targetPath = siblingWorktreePath(mainRoot: mainRoot, directoryName: directoryName)
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
    try Self.validateFilesystemForceRemoval(
      of: worktreePath,
      mainRepoPath: parentRepoPath,
      isRegisteredLinkedWorktree: false
    )
    await forceRemoveDirectory(worktreePath)
    if FileManager.default.fileExists(atPath: worktreePath) {
      throw WorktreeManagementError.gitCommandFailed(
        "Worktree directory still exists after orphan delete: \(worktreePath)"
      )
    }
  }
}

private extension WorktreeManagementService {
  func prepareWorktreePath(repoPath: String, directoryName: String) async throws -> String {
    let mainRoot = try await findMainRepositoryRoot(at: repoPath)
    let worktreePath = siblingWorktreePath(mainRoot: mainRoot, directoryName: directoryName)

    if FileManager.default.fileExists(atPath: worktreePath) {
      throw WorktreeManagementError.directoryAlreadyExists(worktreePath)
    }

    return worktreePath
  }

  nonisolated func launchPath(sourceRoot: String, startPath: String, worktreePath: String) throws -> String {
    let relativePath = try relativeStartPath(sourceRoot: sourceRoot, startPath: startPath)
    guard !relativePath.isEmpty else { return worktreePath }
    return (worktreePath as NSString).appendingPathComponent(relativePath)
  }

  nonisolated func relativeStartPath(sourceRoot: String, startPath: String) throws -> String {
    let normalizedRoot = normalizedExistingPath(sourceRoot)
    let normalizedStart = normalizedExistingPath(startPath)
    if normalizedStart == normalizedRoot {
      return ""
    }

    let prefix = normalizedRoot + "/"
    guard normalizedStart.hasPrefix(prefix) else {
      throw WorktreeManagementError.gitCommandFailed(
        "Start path must be inside the git repository root: \(startPath)"
      )
    }

    return String(normalizedStart.dropFirst(prefix.count))
  }

  func resolvedSparseCheckoutPaths(
    profile: WorktreeSparseCheckoutProfile?,
    relativeStartPath: String,
    treeish: String,
    sourceRoot: String
  ) async throws -> [String] {
    let inference = try await sparseCheckoutInference(
      relativeStartPath: relativeStartPath,
      treeish: treeish,
      sourceRoot: sourceRoot
    )

    let profilePaths: [String]
    if let profile {
      var paths = profile.paths
      if let ownerPath = inference?.ownerPath,
         !Self.sparsePaths(paths, contain: ownerPath) {
        paths.insert(ownerPath, at: 0)
      }
      profilePaths = paths
    } else {
      guard let inference else { return [] }
      profilePaths = inference.paths
    }

    var existingPaths: [String] = []
    for path in profilePaths {
      try validateSparseCheckoutPath(path)
      guard try await trackedPathExists(path, treeish: treeish, sourceRoot: sourceRoot) else { continue }
      if !Self.sparsePaths(existingPaths, contain: path) {
        existingPaths.append(path)
      }
    }

    if let ownerPath = inference?.ownerPath,
       !Self.sparsePaths(existingPaths, contain: ownerPath) {
      guard profile != nil else { return [] }
      throw WorktreeManagementError.gitCommandFailed(
        "Sparse checkout launch path did not match any tracked paths for \(relativeStartPath). Pass tracked sparse paths or request a full checkout."
      )
    }

    return existingPaths
  }

  private func sparseCheckoutInference(
    relativeStartPath: String,
    treeish: String,
    sourceRoot: String
  ) async throws -> SparseCheckoutInference? {
    let normalizedStartPath = WorktreeSparseCheckoutProfile.normalizedPath(relativeStartPath)
    guard !normalizedStartPath.isEmpty else { return nil }

    let markerMatch = try await nearestSparseProjectMarker(
      relativeStartPath: normalizedStartPath,
      treeish: treeish,
      sourceRoot: sourceRoot
    )
    let ownerPath = markerMatch?.ownerPath ?? normalizedStartPath
    var paths = [ownerPath] + WorktreeSparseCheckoutProfile.agentSupportPaths
    if markerMatch?.includesGradleSupport == true {
      paths.append(Self.topLevelGradleSupportPath)
    }

    return SparseCheckoutInference(
      ownerPath: ownerPath,
      paths: WorktreeSparseCheckoutProfile(paths: paths).paths
    )
  }

  private func nearestSparseProjectMarker(
    relativeStartPath: String,
    treeish: String,
    sourceRoot: String
  ) async throws -> SparseProjectMarkerMatch? {
    var nearestGradleBuildMatch: SparseProjectMarkerMatch?

    for candidatePath in sparseOwnerCandidates(for: relativeStartPath) {
      guard let entryNames = try await treeEntryNames(
        at: candidatePath,
        treeish: treeish,
        sourceRoot: sourceRoot
      ) else { continue }

      let hasGradleRootMarker = entryNames.contains(where: Self.isSparseGradleRootMarker)
      let hasGradleBuildMarker = entryNames.contains(where: Self.isSparseGradleBuildMarker)
      if hasGradleRootMarker || entryNames.contains(where: Self.isSparseProjectMarker) {
        return SparseProjectMarkerMatch(
          ownerPath: candidatePath,
          includesGradleSupport: hasGradleRootMarker || hasGradleBuildMarker
        )
      }

      if hasGradleBuildMarker, nearestGradleBuildMatch == nil {
        nearestGradleBuildMatch = SparseProjectMarkerMatch(
          ownerPath: candidatePath,
          includesGradleSupport: true
        )
      }
    }
    return nearestGradleBuildMatch
  }

  private nonisolated func sparseOwnerCandidates(for relativeStartPath: String) -> [String] {
    let components = WorktreeSparseCheckoutProfile.normalizedPath(relativeStartPath)
      .split(separator: "/")
      .map(String.init)
    guard !components.isEmpty else { return [] }

    return stride(from: components.count, through: 1, by: -1).map { count in
      components.prefix(count).joined(separator: "/")
    }
  }

  private func treeEntryNames(
    at relativePath: String,
    treeish: String,
    sourceRoot: String
  ) async throws -> [String]? {
    do {
      let output = try await runGitCommand(
        ["ls-tree", "--name-only", "\(treeish):\(relativePath)"],
        at: sourceRoot
      )
      return output
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    } catch WorktreeManagementError.gitCommandFailed {
      return nil
    }
  }

  private nonisolated static func isSparseProjectMarker(_ name: String) -> Bool {
    sparseProjectMarkerFileNames.contains(name)
      || sparseProjectMarkerSuffixes.contains(where: name.hasSuffix)
  }

  private nonisolated static func isSparseGradleRootMarker(_ name: String) -> Bool {
    sparseGradleRootMarkerFileNames.contains(name)
  }

  private nonisolated static func isSparseGradleBuildMarker(_ name: String) -> Bool {
    sparseGradleBuildMarkerFileNames.contains(name)
  }

  nonisolated func validateSparseCheckoutPath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
      throw WorktreeManagementError.gitCommandFailed("Invalid sparse checkout path: \(path)")
    }
  }

  func trackedPathExists(_ path: String, treeish: String, sourceRoot: String) async throws -> Bool {
    do {
      try await runGitCommand(["cat-file", "-e", "\(treeish):\(path)"], at: sourceRoot)
      return true
    } catch WorktreeManagementError.gitCommandFailed {
      return false
    }
  }

  func configureSparseCheckout(paths: [String], at worktreePath: String) async throws {
    do {
      try await runGitCommand(
        ["sparse-checkout", "init", "--cone", "--sparse-index"],
        at: worktreePath,
        timeout: Self.gitWorktreeTimeout
      )
    } catch {
      try await runGitCommand(
        ["sparse-checkout", "init", "--cone"],
        at: worktreePath,
        timeout: Self.gitWorktreeTimeout
      )
    }

    try await runGitCommand(
      ["sparse-checkout", "set", "--"] + paths,
      at: worktreePath,
      timeout: Self.gitWorktreeTimeout
    )
  }

  static func sparsePaths(_ paths: [String], contain candidate: String) -> Bool {
    paths.contains { path in
      candidate == path || candidate.hasPrefix(path + "/")
    }
  }

  nonisolated func siblingWorktreeDirectory(mainRoot: String) -> String {
    (mainRoot as NSString).deletingLastPathComponent
  }

  nonisolated func siblingWorktreePath(mainRoot: String, directoryName: String) -> String {
    (siblingWorktreeDirectory(mainRoot: mainRoot) as NSString).appendingPathComponent(directoryName)
  }

  func resolveCreatedWorktreePath(
    requestedPath: String,
    branch: String,
    repoPath: String
  ) async -> String {
    let normalizedRequestedPath = normalizedExistingPath(requestedPath)
    if let worktrees = try? await listWorktrees(at: repoPath),
       let gitRegisteredPath = worktrees.first(where: { worktree in
         worktree.branch == branch
           || normalizedExistingPath(worktree.path) == normalizedRequestedPath
       })?.path {
      return gitRegisteredPath
    }

    if let gitRoot = try? await findGitRoot(at: requestedPath), !gitRoot.isEmpty {
      return gitRoot
    }

    return normalizedRequestedPath
  }

  nonisolated func normalizedExistingPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  func registeredWorktree(at worktreePath: String, relativeTo parentRepoPath: String) async throws -> WorktreeInfo? {
    let normalizedTargetPath = normalizedExistingPath(worktreePath)
    return try await listWorktrees(at: parentRepoPath).first { worktree in
      normalizedExistingPath(worktree.path) == normalizedTargetPath
    }
  }

  func pruneStaleWorktreeMetadata(for worktreePath: String, parentRepoPath: String) async throws {
    try await runGitCommand(["worktree", "prune", "--expire", "now"], at: parentRepoPath)
    if let stillRegistered = try await registeredWorktree(at: worktreePath, relativeTo: parentRepoPath),
       stillRegistered.isWorktree {
      throw WorktreeManagementError.gitCommandFailed(
        "Worktree metadata still exists after prune: \(worktreePath)"
      )
    }
  }

  /// Last line of defense before the filesystem fallback deletes a directory git
  /// refused to remove. Require evidence the path is a linked worktree and can
  /// never be the main checkout.
  nonisolated static func validateFilesystemForceRemoval(
    of worktreePath: String,
    mainRepoPath: String,
    isRegisteredLinkedWorktree: Bool
  ) throws {
    let target = (worktreePath as NSString).standardizingPath
    let mainRoot = (mainRepoPath as NSString).standardizingPath
    if target == mainRoot || mainRoot.hasPrefix(target + "/") {
      throw WorktreeManagementError.gitCommandFailed(
        "Refusing to force-delete \(worktreePath): it is or contains the main repository"
      )
    }

    guard isRegisteredLinkedWorktree || hasLinkedWorktreeMarker(at: worktreePath) else {
      throw WorktreeManagementError.gitCommandFailed(
        "Refusing to force-delete \(worktreePath): it is not a registered worktree and has no linked-worktree .git marker"
      )
    }
  }

  /// Whether the directory's `.git` entry is a linked-worktree marker file.
  nonisolated static func hasLinkedWorktreeMarker(at path: String) -> Bool {
    let gitEntry = (path as NSString).appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gitEntry, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          let contents = try? String(contentsOfFile: gitEntry, encoding: .utf8),
          let gitdirLine = contents.components(separatedBy: .newlines).first(where: { $0.hasPrefix("gitdir:") }) else {
      return false
    }
    return gitdirLine.contains("/.git/worktrees/")
  }

  func forceRemoveWorktreeDirectory(_ worktreePath: String, parentRepoPath: String) async throws {
    await forceRemoveDirectory(worktreePath)
    try await pruneStaleWorktreeMetadata(for: worktreePath, parentRepoPath: parentRepoPath)
    if FileManager.default.fileExists(atPath: worktreePath) {
      throw WorktreeManagementError.gitCommandFailed(
        "Worktree directory still exists after force delete: \(worktreePath)"
      )
    }
  }

  /// Removes a directory tree even when it contains read-only files. `chmod -R`
  /// and `rm -rf` do not traverse symlinked directories on macOS, so symlinked
  /// caches outside the tree are left untouched. Callers must validate the path
  /// with `validateFilesystemForceRemoval` first.
  func forceRemoveDirectory(_ path: String) async {
    guard FileManager.default.fileExists(atPath: path) else { return }
    _ = try? await runShellCommand("/bin/chmod", arguments: ["-R", "u+w", path], timeout: 30)
    _ = try? await runShellCommand("/bin/rm", arguments: ["-rf", path], timeout: 60)
  }

  func runShellCommand(
    _ executablePath: String,
    arguments: [String],
    timeout: TimeInterval
  ) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    try process.run()
    let exitCode = await withTaskCancellationHandler {
      await withTaskGroup(of: Int32.self) { group in
        group.addTask {
          process.waitUntilExit()
          return process.terminationStatus
        }
        group.addTask {
          try? await Task.sleep(for: .seconds(timeout))
          if process.isRunning {
            process.terminate()
          }
          return Int32(-1)
        }

        let result = await group.next() ?? Int32(-1)
        group.cancelAll()
        return result
      }
    } onCancel: {
      Self.terminateIfRunning(process)
    }

    if exitCode != 0 {
      throw WorktreeManagementError.gitCommandFailed(
        "\(executablePath) failed with exit code \(exitCode)"
      )
    }
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

  func defaultRemoteBaseBranch(from output: String) -> BranchInfo? {
    let branches = parseRemoteBranches(output)
    guard !branches.isEmpty else { return nil }

    if let headName = remoteHeadTarget(from: output),
       let headBranch = branches.first(where: {
         $0.name == headName && Self.isSupportedDefaultBaseName($0.displayName)
       }) {
      return headBranch
    }

    if let originMain = branches.first(where: { $0.name == "origin/main" }) {
      return originMain
    }

    if let originMaster = branches.first(where: { $0.name == "origin/master" }) {
      return originMaster
    }

    if let remoteMain = branches.first(where: { $0.displayName == "main" }) {
      return remoteMain
    }

    return branches.first(where: { $0.displayName == "master" })
  }

  func remoteHeadTarget(from output: String) -> String? {
    output.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .compactMap { line -> String? in
        guard line.contains("HEAD ->") else { return nil }
        let parts = line.components(separatedBy: "->")
        guard parts.count == 2 else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
      }
      .first
  }

  static func isSupportedDefaultBaseName(_ branchName: String) -> Bool {
    branchName == "main" || branchName == "master"
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

    // Detect exit via terminationHandler — a reliable dispatch source — instead
    // of polling `waitUntilExit()` on a background thread. Under the rapid Process
    // churn of a multi-worktree batch, the background-thread `waitUntilExit` can
    // miss the child-exit notification and hang forever (observed: a wedged git
    // command with no live child and the 10s timeout never firing). Wire the
    // handler BEFORE run() so a near-instant exit can't race ahead of it.
    let exitNotifier = ProcessExitNotifier()
    process.terminationHandler = { exitNotifier.complete(status: $0.terminationStatus) }

    do {
      try process.run()
      try inputPipe.fileHandleForWriting.close()
    } catch {
      throw WorktreeManagementError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
    }

    // Drain stdout and stderr concurrently so a command whose output exceeds the
    // kernel pipe buffer (~64KB) can't fill it, block git's write, and deadlock.
    // Each drain reads to EOF on a background queue; EOF arrives when git exits
    // or is terminated by the timeout below.
    async let outputData = Self.readHandleToEnd(outputPipe.fileHandleForReading)
    async let errorData = Self.readHandleToEnd(errorPipe.fileHandleForReading)

    let didTimeout = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        _ = await exitNotifier.wait()
        return false
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

    let output = String(data: await outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: await errorData, encoding: .utf8) ?? ""

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

  /// Reads a file handle to EOF on a background queue so a pipe can be drained
  /// concurrently with `waitUntilExit()` instead of only after it (which would
  /// deadlock once the kernel pipe buffer fills on large git output).
  nonisolated static func readHandleToEnd(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let data = handle.readDataToEndOfFile()
        continuation.resume(returning: data)
      }
    }
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
    let progressForwarder = WorktreeProgressForwarder(onProgress: onProgress)
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        // EOF: git's stderr write end has closed (the command finished). The
        // dispatch read source keeps firing on a descriptor that is now
        // permanently "readable" — it is signaling EOF — so leaving the handler
        // installed busy-spins the shared `com.apple.NSFileHandle.fd_monitoring`
        // serial queue at 100% CPU. Worse, that same serial queue delivers
        // `Process` termination, so the spin starves `waitUntilExit()` below and
        // the call never reaches the `readabilityHandler = nil` teardown — a
        // self-sustaining livelock that hangs the MCP tool call indefinitely.
        // Remove the handler the instant we observe EOF so the source stops and
        // the process can be reaped. Any trailing partial line is recovered after
        // exit via `stderrCollector.drainPartialLine()`.
        handle.readabilityHandler = nil
        return
      }

      guard let chunk = String(data: data, encoding: .utf8) else { return }

      let lines = stderrCollector.append(chunk)
      for line in lines {
        Self.forwardGitProgress(from: line, using: progressForwarder)
      }
    }

    // Guarantee the stderr handler is torn down on every exit path — including an
    // early throw from `process.run()` below, which would otherwise skip the
    // normal post-exit cleanup and leak the dispatch read source. The happy path
    // also clears it explicitly before the final drain; this backstop is idempotent.
    defer { errorPipe.fileHandleForReading.readabilityHandler = nil }

    activeWorktreeProcesses[operationID] = process
    defer {
      activeWorktreeProcesses.removeValue(forKey: operationID)
    }

    let (exitCode, didTimeout) = try await withTaskCancellationHandler {
      if cancelledWorktreeOperations.contains(operationID) {
        throw WorktreeManagementError.cancelled
      }

      // Reliable exit detection via terminationHandler (see runGitCommand) — wired
      // before run() so a near-instant exit can't race ahead of it — instead of a
      // background-thread waitUntilExit that can miss the notification under rapid
      // Process churn and hang forever.
      let exitNotifier = ProcessExitNotifier()
      process.terminationHandler = { exitNotifier.complete(status: $0.terminationStatus) }

      do {
        try process.run()
        try inputPipe.fileHandleForWriting.close()
      } catch {
        throw WorktreeManagementError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
      }

      return await withTaskGroup(of: (Int32, Bool).self) { group in
        group.addTask {
          let exitCode = await exitNotifier.wait()
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
    var remainingLines: [String] = []
    if let remainingError = String(data: remainingErrorData, encoding: .utf8),
       !remainingError.isEmpty {
      remainingLines.append(contentsOf: stderrCollector.append(remainingError))
    }
    remainingLines.append(contentsOf: stderrCollector.drainPartialLine())
    for line in remainingLines {
      Self.forwardGitProgress(from: line, using: progressForwarder)
    }
    await progressForwarder.waitForAll()

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

  static func forwardGitProgress(
    from line: String,
    using forwarder: WorktreeProgressForwarder
  ) {
    if let progress = parseUpdatingFilesProgress(from: line) {
      forwarder.enqueue(.updatingFiles(current: progress.current, total: progress.total))
    } else if line.contains("Preparing worktree") {
      forwarder.enqueue(.preparing(message: "Preparing worktree..."))
    }
  }

  static func terminateIfRunning(_ process: Process) {
    if process.isRunning {
      process.terminate()
    }
  }
}

/// One-shot bridge from `Process.terminationHandler` to an `async` awaiter.
/// `terminationHandler` is delivered by a dispatch source and is reliable;
/// polling `waitUntilExit()` on a background thread can miss the notification
/// under rapid Process churn and hang forever. The handler fires exactly once
/// (the process exits once), and `wait()` is awaited exactly once per command,
/// so a single stored continuation is sufficient.
private final class ProcessExitNotifier: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32?
  private var continuation: CheckedContinuation<Int32, Never>?

  func complete(status: Int32) {
    lock.lock()
    if let continuation {
      self.continuation = nil
      lock.unlock()
      continuation.resume(returning: status)
    } else {
      self.status = status
      lock.unlock()
    }
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let status {
        lock.unlock()
        continuation.resume(returning: status)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }
}

private final class WorktreeProgressForwarder: @unchecked Sendable {
  private let lock = NSLock()
  private var tailTask: Task<Void, Never>?
  private var generation = 0
  private let onProgress: @Sendable (WorktreeCreationProgress) async -> Void

  init(onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void) {
    self.onProgress = onProgress
  }

  func enqueue(_ progress: WorktreeCreationProgress) {
    lock.lock()
    defer { lock.unlock() }
    let previousTask = tailTask
    generation += 1
    tailTask = Task {
      await previousTask?.value
      await onProgress(progress)
    }
  }

  func waitForAll() async {
    while true {
      let (task, targetGeneration) = currentTail()

      await task?.value

      if isCurrentGeneration(targetGeneration) {
        return
      }
    }
  }

  private func currentTail() -> (Task<Void, Never>?, Int) {
    lock.lock()
    defer { lock.unlock() }
    return (tailTask, generation)
  }

  private func isCurrentGeneration(_ targetGeneration: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == targetGeneration
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

  func drainPartialLine() -> [String] {
    lock.lock()
    defer { lock.unlock() }

    guard !partialLine.isEmpty else { return [] }
    let line = partialLine
    lines.append(line)
    partialLine = ""
    return [line]
  }
}
