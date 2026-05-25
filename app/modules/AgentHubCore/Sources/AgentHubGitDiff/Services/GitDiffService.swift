//
//  GitDiffService.swift
//  AgentHub
//
//  Created by Assistant on 1/19/26.
//

import Foundation
import os

/// Errors that can occur during git diff operations
public enum GitDiffError: LocalizedError, Sendable {
  case gitCommandFailed(String)
  case fileNotFound(String)
  case notAGitRepository(String)
  case timeout
  case binaryFile(String)

  public var errorDescription: String? {
    switch self {
    case .gitCommandFailed(let message):
      return "Git command failed: \(message)"
    case .fileNotFound(let path):
      return "File not found: \(path)"
    case .notAGitRepository(let path):
      return "Not a git repository: \(path)"
    case .timeout:
      return "Git command timed out"
    case .binaryFile(let path):
      return "Binary file: \(path)"
    }
  }
}

/// Service for git diff operations
public protocol GitDiffServiceProtocol: Sendable {
  func changedFiles(at repoPath: String, mode: DiffMode, baseBranch: String?) async throws -> GitDiffState
  func renderPayload(
    for file: GitDiffFileEntry,
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String?
  ) async throws -> GitDiffRenderPayload
  func detectBaseBranch(at repoPath: String) async throws -> String
  func findGitRoot(at path: String) async throws -> String
}

public actor GitDiffService: GitDiffServiceProtocol {

  /// Maximum time to wait for git commands (in seconds)
  private static let gitCommandTimeout: TimeInterval = 30.0
  private static let limitedContextReason = "Large file rendered with changed hunks only."
  private static let backendPrintPrefix = "AGENTHUB_DIFF_BACKEND"
  private static let logger = Logger(subsystem: "com.agenthub.gitdiff", category: "GitDiff")

  private let renderPolicy: GitDiffRenderPolicy
  private var gitRootCache: [String: String] = [:]

  public init(renderPolicy: GitDiffRenderPolicy = .default) {
    self.renderPolicy = renderPolicy
  }

  // MARK: - Public API

  // MARK: - Mode-Aware API

  /// Gets changes based on the specified diff mode
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - mode: The type of diff to retrieve
  ///   - baseBranch: Base branch for branch mode (auto-detected if nil)
  /// - Returns: GitDiffState containing all files with changes
  public func getChanges(
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String? = nil
  ) async throws -> GitDiffState {
    try await changedFiles(at: repoPath, mode: mode, baseBranch: baseBranch)
  }

  public func changedFiles(
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String? = nil
  ) async throws -> GitDiffState {
    do {
      let gitRoot = try await findGitRoot(at: repoPath)
      let branch: String?
      if mode == .branch {
        branch = try await resolvedBaseBranch(baseBranch, repoPath: repoPath)
      } else {
        branch = nil
      }
      let state = try LibGit2DiffBackend.changedFiles(
        atGitRoot: gitRoot,
        mode: mode,
        baseBranch: branch,
        renderPolicy: renderPolicy
      )
      printBackend("changedFiles backend=libgit2 mode=\(mode.rawValue) files=\(state.files.count)")
      return state
    } catch {
      Self.logger.warning("libgit2 changedFiles fallback: \(error.localizedDescription)")
    }

    switch mode {
    case .unstaged:
      return try await getUnstagedChanges(at: repoPath)
    case .staged:
      return try await getStagedChanges(at: repoPath)
    case .branch:
      let branch: String
      if let providedBranch = baseBranch {
        branch = providedBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      return try await getBranchChanges(at: repoPath, baseBranch: branch)
    }
  }

  /// Gets all unstaged changes for a repository
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: GitDiffState containing all files with unstaged changes
  public func getUnstagedChanges(at repoPath: String) async throws -> GitDiffState {
    let gitRoot = try await findGitRoot(at: repoPath)

    let output = try await runGitCommand(["diff", "--numstat"], at: gitRoot)

    var files: [GitDiffFileEntry] = []

    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in lines {
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 3 else { continue }

      let additions = Int(parts[0]) ?? 0
      let deletions = Int(parts[1]) ?? 0
      let relativePath = parts[2]

      let fullPath = (gitRoot as NSString).appendingPathComponent(relativePath)
      files.append(GitDiffFileEntry(
        filePath: fullPath,
        relativePath: relativePath,
        additions: additions,
        deletions: deletions
      ))
    }

    // Include untracked files so newly generated code is visible in diff consumers.
    let untrackedFiles = try await getUntrackedChanges(atGitRoot: gitRoot)
    files.append(contentsOf: untrackedFiles)

    return GitDiffState(files: deduplicateEntriesByRelativePath(files))
  }

  /// Gets all untracked files in the repository.
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: Array of untracked files
  public func getUntrackedChanges(at repoPath: String) async throws -> [GitDiffFileEntry] {
    let gitRoot = try await findGitRoot(at: repoPath)
    return try await getUntrackedChanges(atGitRoot: gitRoot)
  }

  /// Gets all staged changes for a repository
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: GitDiffState containing all files with staged changes
  public func getStagedChanges(at repoPath: String) async throws -> GitDiffState {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get staged changes with --numstat --staged
    let output = try await runGitCommand(["diff", "--staged", "--numstat"], at: gitRoot)

    var files: [GitDiffFileEntry] = []

    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in lines {
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 3 else { continue }

      let additions = Int(parts[0]) ?? 0
      let deletions = Int(parts[1]) ?? 0
      let relativePath = parts[2]

      let fullPath = (gitRoot as NSString).appendingPathComponent(relativePath)
      files.append(GitDiffFileEntry(
        filePath: fullPath,
        relativePath: relativePath,
        additions: additions,
        deletions: deletions
      ))
    }

    return GitDiffState(files: files)
  }

  /// Gets all changes between current branch and base branch
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - baseBranch: The base branch to compare against (e.g., "main", "master")
  /// - Returns: GitDiffState containing all files changed since branching from base
  public func getBranchChanges(at repoPath: String, baseBranch: String) async throws -> GitDiffState {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Use three-dot diff to compare from merge-base to HEAD
    let output = try await runGitCommand(["diff", "\(baseBranch)...HEAD", "--numstat"], at: gitRoot)

    var files: [GitDiffFileEntry] = []

    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in lines {
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 3 else { continue }

      let additions = Int(parts[0]) ?? 0
      let deletions = Int(parts[1]) ?? 0
      let relativePath = parts[2]

      let fullPath = (gitRoot as NSString).appendingPathComponent(relativePath)
      files.append(GitDiffFileEntry(
        filePath: fullPath,
        relativePath: relativePath,
        additions: additions,
        deletions: deletions
      ))
    }

    return GitDiffState(files: files)
  }

  /// Detects the base branch (main or master)
  /// - Parameter repoPath: Path to the git repository
  /// - Returns: The detected base branch name
  public func detectBaseBranch(at repoPath: String) async throws -> String {
    do {
      return try LibGit2DiffBackend.detectBaseBranch(at: repoPath)
    } catch {
      Self.logger.warning("libgit2 detectBaseBranch fallback: \(error.localizedDescription)")
    }

    let gitRoot = try await findGitRoot(at: repoPath)

    // Try "main" first
    do {
      _ = try await runGitCommand(["rev-parse", "--verify", "main"], at: gitRoot)
      return "main"
    } catch {
      // Try "master" as fallback
      do {
        _ = try await runGitCommand(["rev-parse", "--verify", "master"], at: gitRoot)
        return "master"
      } catch {
        throw GitDiffError.gitCommandFailed("Could not detect base branch (tried main, master)")
      }
    }
  }

  // MARK: - Unified Diff Output (Fast Path)

  /// Gets unified diff output directly from git (fast - single command, no file content fetching)
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - mode: The type of diff to retrieve
  ///   - baseBranch: Base branch for branch mode (auto-detected if nil)
  /// - Returns: Raw unified diff output from git
  public func getUnifiedDiffOutput(
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String? = nil
  ) async throws -> String {
    let gitRoot = try await findGitRoot(at: repoPath)

    let command: [String]
    switch mode {
    case .unstaged:
      command = ["diff"]
    case .staged:
      command = ["diff", "--staged"]
    case .branch:
      let branch: String
      if let providedBranch = baseBranch {
        branch = providedBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      command = ["diff", "\(branch)...HEAD"]
    }

    return try await runGitCommand(command, at: gitRoot)
  }

  /// Gets unified diff output for a specific file (fast - single command)
  /// - Parameters:
  ///   - filePath: Absolute path to the file
  ///   - repoPath: Path to the git repository
  ///   - mode: The diff mode (unstaged, staged, or branch)
  ///   - baseBranch: Base branch for branch mode (auto-detected if nil)
  /// - Returns: Raw unified diff output for the file
  public func getUnifiedFileDiff(
    filePath: String,
    at repoPath: String,
    mode: DiffMode = .unstaged,
    baseBranch: String? = nil
  ) async throws -> String {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1))
    } else {
      relativePath = filePath
    }

    let command: [String]
    switch mode {
    case .unstaged:
      command = ["diff", "--", relativePath]
    case .staged:
      command = ["diff", "--staged", "--", relativePath]
    case .branch:
      let branch: String
      if let providedBranch = baseBranch {
        branch = providedBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      command = ["diff", "\(branch)...HEAD", "--", relativePath]
    }

    return try await runGitCommand(command, at: gitRoot)
  }

  /// Gets the diff content for a specific file based on mode
  /// - Parameters:
  ///   - filePath: Absolute path to the file
  ///   - repoPath: Path to the git repository
  ///   - mode: The diff mode (unstaged, staged, or branch)
  ///   - baseBranch: Base branch for branch mode (auto-detected if nil)
  /// - Returns: Tuple of (oldContent, newContent)
  public func getFileDiff(
    filePath: String,
    at repoPath: String,
    mode: DiffMode = .unstaged,
    baseBranch: String? = nil
  ) async throws -> (oldContent: String, newContent: String) {
    switch mode {
    case .unstaged:
      return try await getUnstagedFileDiff(filePath: filePath, at: repoPath)
    case .staged:
      return try await getStagedFileDiff(filePath: filePath, at: repoPath)
    case .branch:
      let branch: String
      if let providedBranch = baseBranch {
        branch = providedBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      return try await getBranchFileDiff(filePath: filePath, at: repoPath, baseBranch: branch)
    }
  }

  public func renderPayload(
    for file: GitDiffFileEntry,
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String? = nil
  ) async throws -> GitDiffRenderPayload {
    if Task.isCancelled {
      throw CancellationError()
    }

    do {
      let gitRoot = try await findGitRoot(at: repoPath)
      let branch: String?
      if mode == .branch {
        branch = try await resolvedBaseBranch(baseBranch, repoPath: repoPath)
      } else {
        branch = nil
      }
      let payload = try LibGit2DiffBackend.renderPayload(
        for: file,
        atGitRoot: gitRoot,
        mode: mode,
        baseBranch: branch,
        renderPolicy: renderPolicy
      )
      printBackend("renderPayload backend=libgit2 mode=\(mode.rawValue) file=\"\(oneLine(file.relativePath))\" renderMode=\(payload.renderMode.rawValue) limited=\(payload.isLimitedContext)")
      return payload
    } catch {
      Self.logger.warning("libgit2 renderPayload fallback for \(file.relativePath): \(error.localizedDescription)")
      assertionFailure("libgit2 renderPayload fallback in \(mode.rawValue) for \(file.relativePath): \(error.localizedDescription)")
    }

    if try await shouldUseLimitedContext(for: file, at: repoPath, mode: mode, baseBranch: baseBranch) {
      let payload = try await limitedContextPayload(for: file, at: repoPath, mode: mode, baseBranch: baseBranch)
      return payload
    }

    do {
      let contents = try await getFileDiff(
        filePath: file.filePath,
        at: repoPath,
        mode: mode,
        baseBranch: baseBranch
      )
      let payload = GitDiffRenderPayload(oldContent: contents.oldContent, newContent: contents.newContent)
      return payload
    } catch {
      if let fallback = try? await limitedContextPayload(for: file, at: repoPath, mode: mode, baseBranch: baseBranch) {
        return fallback
      }
      throw error
    }
  }

  private func shouldUseLimitedContext(
    for file: GitDiffFileEntry,
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String?
  ) async throws -> Bool {
    let gitRoot = try await findGitRoot(at: repoPath)
    let relativePath = relativePath(for: file.filePath, gitRoot: gitRoot)
    let sizes = try await estimatedSideSizes(
      filePath: file.filePath,
      relativePath: relativePath,
      gitRoot: gitRoot,
      repoPath: repoPath,
      mode: mode,
      baseBranch: baseBranch
    )

    return max(sizes.old, sizes.new) > renderPolicy.maxFullContentBytes
  }

  private func estimatedSideSizes(
    filePath: String,
    relativePath: String,
    gitRoot: String,
    repoPath: String,
    mode: DiffMode,
    baseBranch: String?
  ) async throws -> (old: UInt64, new: UInt64) {
    switch mode {
    case .unstaged:
      async let oldSize = gitObjectSize("HEAD:\(relativePath)", at: gitRoot)
      let newSize = localFileSize(filePath)
      return await (oldSize ?? 0, newSize ?? 0)

    case .staged:
      async let oldSize = gitObjectSize("HEAD:\(relativePath)", at: gitRoot)
      async let newSize = gitObjectSize(":\(relativePath)", at: gitRoot)
      return await (oldSize ?? 0, newSize ?? 0)

    case .branch:
      let branch: String
      if let baseBranch {
        branch = baseBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      let base = try await mergeBase(for: branch, gitRoot: gitRoot)
      async let oldSize = gitObjectSize("\(base):\(relativePath)", at: gitRoot)
      async let newSize = gitObjectSize("HEAD:\(relativePath)", at: gitRoot)
      return await (oldSize ?? 0, newSize ?? 0)
    }
  }

  private func limitedContextPayload(
    for file: GitDiffFileEntry,
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String?
  ) async throws -> GitDiffRenderPayload {
    let patch = try await unifiedPatch(for: file, at: repoPath, mode: mode, baseBranch: baseBranch)
    guard let payload = GitDiffPatchRenderAdapter.renderedPayload(
      from: patch,
      limitedContextReason: Self.limitedContextReason
    ) else {
      throw GitDiffError.binaryFile(file.relativePath)
    }
    return payload
  }

  private func unifiedPatch(
    for file: GitDiffFileEntry,
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String?
  ) async throws -> String {
    let gitRoot = try await findGitRoot(at: repoPath)
    let relativePath = relativePath(for: file.filePath, gitRoot: gitRoot)

    let shouldUseNoIndexDiff: Bool
    if mode == .unstaged {
      shouldUseNoIndexDiff = !(try await isTracked(relativePath: relativePath, gitRoot: gitRoot))
    } else {
      shouldUseNoIndexDiff = false
    }

    if shouldUseNoIndexDiff {
      return try await runGitCommand(
        ["diff", "--no-index", "--", "/dev/null", relativePath],
        at: gitRoot,
        allowedExitCodes: [0, 1]
      )
    }

    return try await getUnifiedFileDiff(
      filePath: file.filePath,
      at: repoPath,
      mode: mode,
      baseBranch: baseBranch
    )
  }

  /// Gets the diff content for an unstaged file (old content from HEAD, new content from disk)
  private func getUnstagedFileDiff(filePath: String, at repoPath: String) async throws -> (oldContent: String, newContent: String) {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1)) // +1 for trailing slash
    } else {
      relativePath = filePath
    }

    // Get old content from HEAD
    var oldContent = ""
    do {
      oldContent = try await runGitCommand(["show", "HEAD:\(relativePath)"], at: gitRoot)
    } catch {
      // File might be new (untracked), so old content is empty
    }

    // Get new content from disk
    var newContent = ""
    let fileURL = URL(fileURLWithPath: filePath)
    if FileManager.default.fileExists(atPath: filePath) {
      do {
        newContent = try String(contentsOf: fileURL, encoding: .utf8)
      } catch {
        Self.logger.error("Could not read file from disk: \(error.localizedDescription)")
        throw GitDiffError.fileNotFound(filePath)
      }
    }

    return (oldContent, newContent)
  }

  /// Gets the diff content for a staged file (old content from HEAD, new content from index)
  private func getStagedFileDiff(filePath: String, at repoPath: String) async throws -> (oldContent: String, newContent: String) {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1))
    } else {
      relativePath = filePath
    }

    // Get old content from HEAD and new content from index in parallel
    async let oldTask = fetchGitFileContent(ref: "HEAD", relativePath: relativePath, gitRoot: gitRoot)
    async let newTask = fetchGitFileContent(ref: "", relativePath: relativePath, gitRoot: gitRoot) // empty ref = index

    let (oldContent, newContent) = await (oldTask, newTask)
    return (oldContent, newContent)
  }

  /// Gets the diff content for a branch file (old content from merge-base, new content from HEAD)
  private func getBranchFileDiff(filePath: String, at repoPath: String, baseBranch: String) async throws -> (oldContent: String, newContent: String) {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1))
    } else {
      relativePath = filePath
    }

    let mergeBase = try await mergeBase(for: baseBranch, gitRoot: gitRoot)

    // Get old content from merge-base and new content from HEAD in parallel
    async let oldTask = fetchGitFileContent(ref: mergeBase, relativePath: relativePath, gitRoot: gitRoot)
    async let newTask = fetchGitFileContent(ref: "HEAD", relativePath: relativePath, gitRoot: gitRoot)

    let (oldContent, newContent) = await (oldTask, newTask)
    return (oldContent, newContent)
  }

  /// Helper to fetch file content from a git ref (or index if ref is empty)
  private func fetchGitFileContent(ref: String, relativePath: String, gitRoot: String) async -> String {
    do {
      if ref.isEmpty {
        // Empty ref means staging area (index): "git show :file"
        return try await runGitCommand(["show", ":\(relativePath)"], at: gitRoot)
      } else {
        return try await runGitCommand(["show", "\(ref):\(relativePath)"], at: gitRoot)
      }
    } catch {
      // File might be new or deleted
      return ""
    }
  }

  private func relativePath(for filePath: String, gitRoot: String) -> String {
    if filePath == gitRoot {
      return ""
    }

    let prefix = gitRoot.hasSuffix("/") ? gitRoot : "\(gitRoot)/"
    if filePath.hasPrefix(prefix) {
      return String(filePath.dropFirst(prefix.count))
    }
    return filePath
  }

  private func gitObjectSize(_ spec: String, at gitRoot: String) async -> UInt64? {
    guard let output = try? await runGitCommand(["cat-file", "-s", spec], at: gitRoot) else {
      return nil
    }

    return UInt64(output.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func localFileSize(_ filePath: String) -> UInt64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
          let size = attributes[.size] as? NSNumber else {
      return nil
    }
    return size.uint64Value
  }

  private func mergeBase(for baseBranch: String, gitRoot: String) async throws -> String {
    let output = try await runGitCommand(["merge-base", baseBranch, "HEAD"], at: gitRoot)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func printBackend(_ message: String) {
    print("\(Self.backendPrintPrefix) \(message)")
  }

  private func oneLine(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }

  private func resolvedBaseBranch(_ baseBranch: String?, repoPath: String) async throws -> String {
    if let baseBranch, !baseBranch.isEmpty {
      return baseBranch
    }
    return try await detectBaseBranch(at: repoPath)
  }

  private func isTracked(relativePath: String, gitRoot: String) async throws -> Bool {
    do {
      _ = try await runGitCommand(["ls-files", "--error-unmatch", "--", relativePath], at: gitRoot)
      return true
    } catch {
      return false
    }
  }

  /// Gets all untracked files when git root is already known.
  /// - Parameter gitRoot: Absolute git root path
  /// - Returns: Array of untracked files
  public func getUntrackedChanges(atGitRoot gitRoot: String) async throws -> [GitDiffFileEntry] {
    let output = try await runGitCommand(
      ["ls-files", "--others", "--exclude-standard", "-z"],
      at: gitRoot
    )
    let relativePaths = output.components(separatedBy: "\u{0}").filter { !$0.isEmpty }

    let entries = relativePaths.map { relativePath in
      let fullPath = (gitRoot as NSString).appendingPathComponent(relativePath)
      return GitDiffFileEntry(
        filePath: fullPath,
        relativePath: relativePath,
        // Avoid reading each untracked file eagerly for line stats.
        additions: 0,
        deletions: 0,
        status: .untracked
      )
    }

    return entries.sorted {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
  }

  /// Deduplicates entries by relative path while preserving first occurrence order.
  private func deduplicateEntriesByRelativePath(_ entries: [GitDiffFileEntry]) -> [GitDiffFileEntry] {
    var seen = Set<String>()
    var result: [GitDiffFileEntry] = []
    result.reserveCapacity(entries.count)

    for entry in entries where seen.insert(entry.relativePath).inserted {
      result.append(entry)
    }

    return result
  }

  // MARK: - Git Root Detection

  /// Finds the git root directory from any path within a repository
  public func findGitRoot(at path: String) async throws -> String {
    if let cached = gitRootCache[path] {
      return cached
    }

    do {
      let root = try LibGit2DiffBackend.findGitRoot(at: path)
      gitRootCache[path] = root
      return root
    } catch {
      Self.logger.warning("libgit2 findGitRoot fallback: \(error.localizedDescription)")
    }

    let output = try await runGitCommand(["rev-parse", "--show-toplevel"], at: path)
    let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
    gitRootCache[path] = root
    return root
  }

  // MARK: - Helper Methods

  /// Runs a git command and returns the output
  private func runGitCommand(
    _ arguments: [String],
    at path: String,
    timeout: TimeInterval = gitCommandTimeout,
    allowedExitCodes: Set<Int32> = [0]
  ) async throws -> String {

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    // Prevent git from prompting for credentials/input
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    process.environment = environment

    // Provide empty stdin to prevent waiting for input
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
      Self.logger.error("Failed to start git process: \(error.localizedDescription)")
      throw GitDiffError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
    }

    // CRITICAL: Read stdout/stderr concurrently BEFORE waiting for process exit
    // This prevents deadlock when output is large enough to fill the pipe buffer.
    // If we wait first, the process blocks trying to write, but we're waiting for it to exit.
    var outputData: Data?
    var errorData: Data?
    let readGroup = DispatchGroup()

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      outputData = try? outputPipe.fileHandleForReading.readToEnd()
      readGroup.leave()
    }

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      errorData = try? errorPipe.fileHandleForReading.readToEnd()
      readGroup.leave()
    }

    // Wait for reads to complete with timeout
    let didTimeout = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          DispatchQueue.global().async {
            // Wait for reads first
            readGroup.wait()
            // Then wait for process to exit
            process.waitUntilExit()
            continuation.resume(returning: false)
          }
        }
      }

      group.addTask {
        do {
          try await Task.sleep(for: .seconds(timeout))
          if process.isRunning {
            Self.logger.warning("Git command timed out after \(timeout)s, terminating")
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

    let output = String(data: outputData ?? Data(), encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData ?? Data(), encoding: .utf8) ?? ""

    if didTimeout {
      throw GitDiffError.timeout
    }

    if !allowedExitCodes.contains(process.terminationStatus) {
      throw GitDiffError.gitCommandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return output
  }
}
