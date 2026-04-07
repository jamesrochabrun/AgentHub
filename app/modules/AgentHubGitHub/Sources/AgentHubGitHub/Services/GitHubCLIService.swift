//
//  GitHubCLIService.swift
//  AgentHub
//
//  Service for interacting with GitHub via the gh CLI
//

import Foundation

// MARK: - Errors

public enum GitHubCLIError: LocalizedError, Sendable {
  case cliNotInstalled
  case notAuthenticated
  case commandFailed(String)
  case notAGitRepository
  case noRemoteRepository
  case parseError(String)
  case timeout

  public var errorDescription: String? {
    switch self {
    case .cliNotInstalled:
      return "GitHub CLI (gh) is not installed. Install it from https://cli.github.com"
    case .notAuthenticated:
      return "Not authenticated with GitHub. Run 'gh auth login' in your terminal."
    case .commandFailed(let message):
      return "GitHub CLI command failed: \(message)"
    case .notAGitRepository:
      return "Not a git repository"
    case .noRemoteRepository:
      return "No GitHub remote found for this repository"
    case .parseError(let message):
      return "Failed to parse GitHub response: \(message)"
    case .timeout:
      return "GitHub CLI command timed out"
    }
  }
}

// MARK: - GitHubCLIService

/// Actor that executes GitHub CLI commands and parses results
public actor GitHubCLIService {

  private static let commandTimeout: TimeInterval = 30.0
  static let checksJSONFields = "name,state,link,bucket"

  /// Cached gh executable path
  private var ghPath: String?

  /// Cached authentication status per repo
  private var authStatusCache: [String: Bool] = [:]

  public init() {}

  // MARK: - CLI Detection

  /// Checks if the gh CLI is installed and returns its path
  public func findGHExecutable() async -> String? {
    if let cached = ghPath {
      return cached
    }

    let searchPaths = [
      "/opt/homebrew/bin/gh",
      "/usr/local/bin/gh",
      "/usr/bin/gh",
      "\(NSHomeDirectory())/.local/bin/gh"
    ]

    for path in searchPaths {
      if FileManager.default.isExecutableFile(atPath: path) {
        ghPath = path
        return path
      }
    }

    // Try `which gh` as fallback
    do {
      let output = try await runCommand("/usr/bin/which", arguments: ["gh"])
      let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
        ghPath = path
        return path
      }
    } catch {
      // Not found
    }

    return nil
  }

  /// Checks if gh is installed
  public func isInstalled() async -> Bool {
    await findGHExecutable() != nil
  }

  /// Checks if user is authenticated with gh
  public func isAuthenticated(at repoPath: String) async -> Bool {
    if let cached = authStatusCache[repoPath] {
      return cached
    }
    do {
      _ = try await runGH(["auth", "status"], at: repoPath)
      authStatusCache[repoPath] = true
      return true
    } catch {
      authStatusCache[repoPath] = false
      return false
    }
  }

  // MARK: - Repository Info

  /// Gets repository information for the current directory
  public func getRepoInfo(at repoPath: String) async throws -> GitHubRepoInfo {
    let json = try await runGH(
      ["repo", "view", "--json", "owner,name,nameWithOwner,defaultBranchRef,isPrivate,url"],
      at: repoPath
    )

    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid response encoding")
    }

    let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let raw else {
      throw GitHubCLIError.parseError("Expected JSON object")
    }

    let ownerObj = raw["owner"] as? [String: Any]
    let defaultBranchObj = raw["defaultBranchRef"] as? [String: Any]

    return GitHubRepoInfo(
      owner: ownerObj?["login"] as? String ?? "",
      name: raw["name"] as? String ?? "",
      fullName: raw["nameWithOwner"] as? String ?? "",
      defaultBranch: defaultBranchObj?["name"] as? String ?? "main",
      isPrivate: raw["isPrivate"] as? Bool ?? false,
      url: raw["url"] as? String ?? ""
    )
  }

  // MARK: - Pull Requests

  /// Lists pull requests for the repository
  public func listPullRequests(
    at repoPath: String,
    state: String = "open",
    limit: Int = 30,
    authoredByMe: Bool = false,
    labels: [String] = []
  ) async throws -> [GitHubPullRequest] {
    let fields = "number,title,body,state,url,headRefName,baseRefName,author,createdAt,updatedAt,isDraft,mergeable,additions,deletions,changedFiles,reviewDecision,statusCheckRollup,labels,reviewRequests"

    let effectiveLimit = authoredByMe ? 200 : limit
    GitHubLogger.github.debug("[PR list] fetching state=\(state) limit=\(effectiveLimit) authoredByMe=\(authoredByMe) labels=\(labels) repoPath=\(repoPath)")
    var args = ["pr", "list", "--state", state, "--limit", "\(effectiveLimit)", "--json", fields]
    if authoredByMe { args += ["--author", "@me"] }
    for label in labels { args += ["--label", label] }

    let startTime = Date()
    let json = try await runGH(args, at: repoPath)
    let elapsed = Date().timeIntervalSince(startTime)
    let bytes = json.utf8.count
    GitHubLogger.github.debug("[PR list] fetched in \(elapsed)s (\(bytes) bytes)")

    let prs = try decodePRList(json)
    GitHubLogger.github.debug("[PR list] decoded \(prs.count) PRs")
    return prs
  }

  /// Lists labels defined in the repository
  public func listLabels(at repoPath: String) async throws -> [GitHubLabel] {
    let json = try await runGH(
      ["label", "list", "--json", "name,color,description", "--limit", "100"],
      at: repoPath
    )

    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid encoding")
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    do {
      return try decoder.decode([GitHubLabel].self, from: data)
    } catch {
      GitHubLogger.github.error("Failed to decode labels: \(error.localizedDescription)")
      throw GitHubCLIError.parseError(error.localizedDescription)
    }
  }

  /// Gets details of a specific pull request
  public func getPullRequest(
    number: Int,
    at repoPath: String
  ) async throws -> GitHubPullRequest {
    let fields = "number,title,body,state,url,headRefName,baseRefName,author,createdAt,updatedAt,isDraft,mergeable,additions,deletions,changedFiles,reviewDecision,statusCheckRollup,labels,reviewRequests,comments"

    let json = try await runGH(
      ["pr", "view", "\(number)", "--json", fields],
      at: repoPath
    )

    return try decodePR(json)
  }

  /// Gets the PR for the current branch (if any)
  public func getCurrentBranchPR(at repoPath: String) async throws -> GitHubPullRequest? {
    let fields = "number,title,body,state,url,headRefName,baseRefName,author,createdAt,updatedAt,isDraft,mergeable,additions,deletions,changedFiles,reviewDecision,statusCheckRollup,labels,reviewRequests,comments"

    do {
      let json = try await runGH(
        ["pr", "view", "--json", fields],
        at: repoPath
      )
      return try decodePR(json)
    } catch let error as GitHubCLIError {
      if case .commandFailed(let msg) = error, msg.contains("no pull requests found") {
        return nil
      }
      throw error
    }
  }

  /// Gets the diff for a pull request
  public func getPullRequestDiff(
    number: Int,
    at repoPath: String
  ) async throws -> String {
    try await runGH(["pr", "diff", "\(number)"], at: repoPath)
  }

  /// Gets files changed in a pull request
  public func getPullRequestFiles(
    number: Int,
    at repoPath: String
  ) async throws -> [GitHubPRFile] {
    let json = try await runGH(
      ["pr", "diff", "\(number)", "--name-only"],
      at: repoPath
    )

    // gh pr diff --name-only returns one filename per line
    let filenames = json.components(separatedBy: "\n").filter { !$0.isEmpty }

    // Get detailed file info via the API
    let apiJson = try await runGH(
      ["api", "repos/{owner}/{repo}/pulls/\(number)/files", "--paginate", "--slurp"],
      at: repoPath
    )

    return try Self.parsePRFiles(apiJson, fallbackFilenames: filenames)
  }

  /// Gets review comments on a pull request
  public func getPullRequestReviewComments(
    number: Int,
    at repoPath: String
  ) async throws -> [GitHubComment] {
    let json = try await runGH(
      ["api", "repos/{owner}/{repo}/pulls/\(number)/comments", "--paginate", "--slurp"],
      at: repoPath
    )

    return try Self.parseReviewComments(json)
  }

  /// Creates a new pull request
  public func createPullRequest(
    input: GitHubPRCreationInput,
    at repoPath: String
  ) async throws -> GitHubPullRequest {
    var args = [
      "pr", "create",
      "--title", input.title,
      "--body", input.body,
      "--base", input.baseBranch,
      "--head", input.headBranch
    ]

    if input.isDraft {
      args.append("--draft")
    }

    for label in input.labels {
      args.append(contentsOf: ["--label", label])
    }

    for reviewer in input.reviewers {
      args.append(contentsOf: ["--reviewer", reviewer])
    }

    let output = try await runGH(args, at: repoPath)

    // gh pr create returns the PR URL; parse the number from it
    let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if let lastComponent = URL(string: url)?.lastPathComponent, let prNumber = Int(lastComponent) {
      return try await getPullRequest(number: prNumber, at: repoPath)
    }

    throw GitHubCLIError.parseError("Could not parse PR number from output: \(output)")
  }

  /// Submits a review on a pull request
  public func submitReview(
    prNumber: Int,
    review: GitHubReviewInput,
    at repoPath: String
  ) async throws {
    var args = ["pr", "review", "\(prNumber)"]

    switch review.event {
    case .approve:
      args.append("--approve")
    case .requestChanges:
      args.append("--request-changes")
    case .comment:
      args.append("--comment")
    }

    if !review.body.isEmpty {
      args.append(contentsOf: ["--body", review.body])
    }

    _ = try await runGH(args, at: repoPath)
  }

  /// Adds a comment to a pull request
  public func addPRComment(
    prNumber: Int,
    body: String,
    at repoPath: String
  ) async throws {
    _ = try await runGH(
      ["pr", "comment", "\(prNumber)", "--body", body],
      at: repoPath
    )
  }

  /// Merges a pull request
  public func mergePullRequest(
    number: Int,
    method: String = "merge",
    at repoPath: String
  ) async throws {
    var args = ["pr", "merge", "\(number)"]
    switch method {
    case "squash":
      args.append("--squash")
    case "rebase":
      args.append("--rebase")
    default:
      args.append("--merge")
    }
    _ = try await runGH(args, at: repoPath)
  }

  /// Checks out a PR branch locally
  public func checkoutPR(
    number: Int,
    at repoPath: String
  ) async throws {
    _ = try await runGH(["pr", "checkout", "\(number)"], at: repoPath)
  }

  // MARK: - Issues

  /// Lists issues for the repository
  public func listIssues(
    at repoPath: String,
    state: String = "open",
    limit: Int = 30
  ) async throws -> [GitHubIssue] {
    let fields = "number,title,body,state,url,author,createdAt,updatedAt,labels,assignees,comments"

    let json = try await runGH(
      ["issue", "list", "--state", state, "--limit", "\(limit)", "--json", fields],
      at: repoPath
    )

    return try decodeIssueList(json)
  }

  /// Gets details of a specific issue
  public func getIssue(
    number: Int,
    at repoPath: String
  ) async throws -> GitHubIssue {
    let fields = "number,title,body,state,url,author,createdAt,updatedAt,labels,assignees,comments"

    let json = try await runGH(
      ["issue", "view", "\(number)", "--json", fields],
      at: repoPath
    )

    return try decodeIssue(json)
  }

  /// Adds a comment to an issue
  public func addIssueComment(
    issueNumber: Int,
    body: String,
    at repoPath: String
  ) async throws {
    _ = try await runGH(
      ["issue", "comment", "\(issueNumber)", "--body", body],
      at: repoPath
    )
  }

  // MARK: - CI/CD Status

  /// Gets CI check status for a PR or the current branch
  public func getChecks(
    prNumber: Int? = nil,
    at repoPath: String
  ) async throws -> [GitHubCheckRun] {
    var args = ["pr", "checks"]
    if let number = prNumber {
      args.append("\(number)")
    }
    args.append(contentsOf: ["--json", Self.checksJSONFields])

    let json = try await runGH(args, at: repoPath, allowedExitCodes: [0, 8])
    return try Self.decodeCheckRuns(json)
  }

  // MARK: - Notifications / Workflow Runs

  /// Lists recent workflow runs
  public func listWorkflowRuns(
    at repoPath: String,
    limit: Int = 10
  ) async throws -> String {
    try await runGH(
      ["run", "list", "--limit", "\(limit)"],
      at: repoPath
    )
  }

  // MARK: - Private Helpers

  /// Runs a gh command and returns stdout
  private func runGH(
    _ arguments: [String],
    at path: String,
    timeout: TimeInterval = commandTimeout,
    allowedExitCodes: Set<Int> = [0]
  ) async throws -> String {
    guard let executable = await findGHExecutable() else {
      throw GitHubCLIError.cliNotInstalled
    }

    return try await runCommand(
      executable,
      arguments: arguments,
      at: path,
      timeout: timeout,
      allowedExitCodes: allowedExitCodes
    )
  }

  /// Runs a command with arguments and returns stdout
  private func runCommand(
    _ executable: String,
    arguments: [String],
    at path: String? = nil,
    timeout: TimeInterval = commandTimeout,
    allowedExitCodes: Set<Int> = [0]
  ) async throws -> String {
    let cmdDescription = ([executable] + arguments).joined(separator: " ")
    GitHubLogger.github.debug("[runCommand] START timeout=\(timeout)s cmd=\(cmdDescription)")
    let cmdStart = Date()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    if let path {
      process.currentDirectoryURL = URL(fileURLWithPath: path)
    }

    // Inherit environment for gh auth tokens
    var environment = ProcessInfo.processInfo.environment
    environment["GH_PROMPT_DISABLED"] = "1"
    environment["NO_COLOR"] = "1"
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
      GitHubLogger.github.error("Failed to start gh process: \(error.localizedDescription)")
      throw GitHubCLIError.commandFailed("Failed to start gh: \(error.localizedDescription)")
    }

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

    let didTimeout = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          DispatchQueue.global().async {
            readGroup.wait()
            process.waitUntilExit()
            continuation.resume(returning: false)
          }
        }
      }

      group.addTask {
        do {
          try await Task.sleep(for: .seconds(timeout))
          if process.isRunning {
            GitHubLogger.github.warning("gh command timed out after \(timeout)s, terminating")
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
    let cmdElapsed = Date().timeIntervalSince(cmdStart)
    let outputBytes = outputData?.count ?? 0

    if didTimeout {
      GitHubLogger.github.error("[runCommand] TIMEOUT after \(cmdElapsed)s cmd=\(cmdDescription)")
      throw GitHubCLIError.timeout
    }

    if !allowedExitCodes.contains(Int(process.terminationStatus)) {
      let errMsg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      let exitCode = process.terminationStatus
      GitHubLogger.github.error("[runCommand] FAILED in \(cmdElapsed)s exitCode=\(exitCode) stderr=\(errMsg) cmd=\(cmdDescription)")

      if errMsg.contains("not logged") || errMsg.contains("auth login") {
        throw GitHubCLIError.notAuthenticated
      }
      if errMsg.contains("not a git repository") {
        throw GitHubCLIError.notAGitRepository
      }
      if errMsg.contains("could not determine repo") || errMsg.contains("no GitHub remotes") {
        throw GitHubCLIError.noRemoteRepository
      }

      throw GitHubCLIError.commandFailed(errMsg)
    }

    GitHubLogger.github.debug("[runCommand] OK in \(cmdElapsed)s stdout=\(outputBytes) bytes cmd=\(cmdDescription)")
    return output
  }

  // MARK: - JSON Parsing

  private func decodePRList(_ json: String) throws -> [GitHubPullRequest] {
    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid encoding")
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    do {
      return try decoder.decode([GitHubPullRequest].self, from: data)
    } catch {
      GitHubLogger.github.error("Failed to decode PR list: \(error.localizedDescription)")
      throw GitHubCLIError.parseError(error.localizedDescription)
    }
  }

  private func decodePR(_ json: String) throws -> GitHubPullRequest {
    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid encoding")
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    do {
      return try decoder.decode(GitHubPullRequest.self, from: data)
    } catch {
      GitHubLogger.github.error("Failed to decode PR: \(error.localizedDescription)")
      throw GitHubCLIError.parseError(error.localizedDescription)
    }
  }

  private func decodeIssueList(_ json: String) throws -> [GitHubIssue] {
    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid encoding")
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    do {
      return try decoder.decode([GitHubIssue].self, from: data)
    } catch {
      GitHubLogger.github.error("Failed to decode issue list: \(error.localizedDescription)")
      throw GitHubCLIError.parseError(error.localizedDescription)
    }
  }

  private func decodeIssue(_ json: String) throws -> GitHubIssue {
    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid encoding")
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    do {
      return try decoder.decode(GitHubIssue.self, from: data)
    } catch {
      GitHubLogger.github.error("Failed to decode issue: \(error.localizedDescription)")
      throw GitHubCLIError.parseError(error.localizedDescription)
    }
  }

  static func decodeCheckRuns(_ json: String) throws -> [GitHubCheckRun] {
    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid encoding")
    }

    let decoder = JSONDecoder()
    struct RawCheck: Decodable {
      let name: String
      let state: String
      let bucket: String?
      let link: String?
    }

    do {
      let rawChecks = try decoder.decode([RawCheck].self, from: data)
      return rawChecks.map { raw in
        GitHubCheckRun(
          name: raw.name,
          status: raw.state,
          bucket: raw.bucket,
          detailsUrl: raw.link
        )
      }
    } catch {
      GitHubLogger.github.error("Failed to decode check runs: \(error.localizedDescription)")
      throw GitHubCLIError.parseError(error.localizedDescription)
    }
  }

  static func parsePRFiles(_ json: String, fallbackFilenames: [String]) throws -> [GitHubPRFile] {
    guard let data = json.data(using: .utf8) else {
      // Fallback to just filenames
      return fallbackFilenames.map { GitHubPRFile(filename: $0, status: "modified", additions: 0, deletions: 0, patch: nil) }
    }

    struct RawFile: Decodable {
      let filename: String
      let status: String?
      let additions: Int?
      let deletions: Int?
      let patch: String?
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    do {
      let rawFiles = try decodePaginatedArray(RawFile.self, from: data, using: decoder)
      return rawFiles.map { raw in
        GitHubPRFile(
          filename: raw.filename,
          status: raw.status ?? "modified",
          additions: raw.additions ?? 0,
          deletions: raw.deletions ?? 0,
          patch: raw.patch
        )
      }
    } catch {
      // Fallback to filenames only
      return fallbackFilenames.map { GitHubPRFile(filename: $0, status: "modified", additions: 0, deletions: 0, patch: nil) }
    }
  }

  static func parseReviewComments(_ json: String) throws -> [GitHubComment] {
    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid encoding")
    }

    struct RawComment: Decodable {
      let id: Int?
      let user: RawUser?
      let body: String?
      let created_at: String?
      let path: String?
      let line: Int?
      let diff_hunk: String?
    }

    struct RawUser: Decodable {
      let login: String?
    }

    let rawComments: [RawComment]
    do {
      rawComments = try decodePaginatedArray(RawComment.self, from: data, using: JSONDecoder())
    } catch {
      GitHubLogger.github.error("Failed to decode review comments: \(error.localizedDescription)")
      throw GitHubCLIError.parseError(error.localizedDescription)
    }

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    return rawComments.compactMap { raw in
      guard let body = raw.body else { return nil }
      return GitHubComment(
        id: raw.id.map { String($0) },
        author: raw.user.flatMap { u in u.login.map { GitHubAuthor(login: $0, name: nil) } },
        body: body,
        createdAt: raw.created_at.flatMap { dateFormatter.date(from: $0) },
        path: raw.path,
        line: raw.line,
        diffHunk: raw.diff_hunk
      )
    }
  }

  private static func decodePaginatedArray<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    using decoder: JSONDecoder
  ) throws -> [T] {
    if let nested = try? decoder.decode([[T]].self, from: data) {
      return nested.flatMap { $0 }
    }
    return try decoder.decode([T].self, from: data)
  }
}

// MARK: - Protocol Conformance

extension GitHubCLIService: GitHubCLIServiceProtocol {}
