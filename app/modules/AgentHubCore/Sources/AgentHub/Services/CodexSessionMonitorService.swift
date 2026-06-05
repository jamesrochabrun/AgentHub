//
//  CodexSessionMonitorService.swift
//  AgentHub
//
//  Service for monitoring Codex CLI sessions from the ~/.codex folder.
//

import Combine
import Foundation

public actor CodexSessionMonitorService {

  // MARK: - Configuration

  private let codexDataPath: String
  private let metadataStore: SessionMetadataStore?

  // MARK: - Publishers

  private nonisolated(unsafe) let repositoriesSubject = CurrentValueSubject<[SelectedRepository], Never>([])
  public nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    repositoriesSubject.eraseToAnyPublisher()
  }

  // MARK: - State

  private var selectedRepositories: [SelectedRepository] = []
  private var ownedWorktreePaths: Set<String> = []
  private var focusedSessionIds: Set<String> = []
  private var ignoredWorktreePathsByRepository: [String: Set<String>] = [:]

  // MARK: - Initialization

  public init(codexDataPath: String? = nil, metadataStore: SessionMetadataStore? = nil) {
    self.codexDataPath = codexDataPath ?? (NSHomeDirectory() + "/.codex")
    self.metadataStore = metadataStore
  }

  // MARK: - Repository Management

  @discardableResult
  public func addRepository(_ path: String) async -> SelectedRepository? {
    await markInputWorktreeAsOwnedIfNeeded(path)
    let repositoryPath = await normalizedRepositoryPath(for: path)
    guard !selectedRepositories.contains(where: { $0.path == repositoryPath }) else {
      return nil
    }

    let worktrees = await detectWorktrees(at: repositoryPath)
    let repository = SelectedRepository(
      path: repositoryPath,
      worktrees: worktrees,
      isExpanded: true
    )

    selectedRepositories.append(repository)
    await refreshSessions(skipWorktreeRedetection: true)
    return repository
  }

  public func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository] {
    for path in paths {
      await markInputWorktreeAsOwnedIfNeeded(path)
    }
    let uniquePaths = await normalizedRepositoryPaths(paths)

    guard !uniquePaths.isEmpty else {
      selectedRepositories = []
      repositoriesSubject.send([])
      return []
    }

    let allWorktrees = await detectWorktreesBatch(repoPaths: uniquePaths)
    selectedRepositories = uniquePaths.map { path in
      SelectedRepository(
        path: path,
        worktrees: allWorktrees[path] ?? [],
        isExpanded: true
      )
    }
    repositoriesSubject.send(selectedRepositories)
    return selectedRepositories
  }

  public func removeRepository(_ path: String) async {
    let repositoryPath = await normalizedRepositoryPath(for: path)
    if let repository = selectedRepositories.first(where: { $0.path == repositoryPath }) {
      ownedWorktreePaths.subtract(repository.worktrees.map(\.path))
    }
    ignoredWorktreePathsByRepository.removeValue(forKey: repositoryPath)
    selectedRepositories.removeAll { $0.path == repositoryPath }
    repositoriesSubject.send(selectedRepositories)
  }

  public func setOwnedWorktreePaths(_ paths: Set<String>) async {
    ownedWorktreePaths = Set(paths.map { WorktreeModuleResolver.normalizedDirectoryPath($0) })
  }

  public func setFocusedSessionIds(_ ids: Set<String>) async {
    focusedSessionIds = ids
  }

  public func registerWorktree(_ worktree: WorktreeBranch, parentRepositoryPath: String) async {
    let repositoryPath = await normalizedRepositoryPath(for: parentRepositoryPath)
    let normalizedWorktree = WorktreeBranch(
      name: worktree.name,
      path: WorktreeModuleResolver.normalizedDirectoryPath(worktree.path),
      isWorktree: worktree.isWorktree,
      sessions: worktree.sessions,
      isExpanded: true
    )
    if normalizedWorktree.isWorktree {
      ownedWorktreePaths.insert(normalizedWorktree.path)
      ignoredWorktreePathsByRepository[repositoryPath]?.remove(normalizedWorktree.path)
    }

    if let index = selectedRepositories.firstIndex(where: { $0.path == repositoryPath }) {
      upsertWorktree(normalizedWorktree, inRepositoryAt: index)
      repositoriesSubject.send(selectedRepositories)
      return
    }

    var worktrees = await detectWorktrees(at: repositoryPath)
    if !worktrees.contains(where: { $0.path == normalizedWorktree.path }) {
      worktrees.append(normalizedWorktree)
    }
    selectedRepositories.append(SelectedRepository(
      path: repositoryPath,
      worktrees: worktrees,
      isExpanded: true
    ))
    repositoriesSubject.send(selectedRepositories)
  }

  public func getSelectedRepositories() async -> [SelectedRepository] {
    selectedRepositories
  }

  public func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    selectedRepositories = repositories
    await refreshSessions()
  }

  private func normalizedRepositoryPath(for path: String) async -> String {
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(path)
    guard let info = await GitWorktreeDetector.detectWorktreeInfo(for: normalizedPath),
          info.isWorktree,
          let mainRepoPath = info.mainRepoPath,
          !mainRepoPath.isEmpty else {
      return normalizedPath
    }
    return WorktreeModuleResolver.normalizedDirectoryPath(mainRepoPath)
  }

  private func markInputWorktreeAsOwnedIfNeeded(_ path: String) async {
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(path)
    guard let info = await GitWorktreeDetector.detectWorktreeInfo(for: normalizedPath),
          info.isWorktree else {
      return
    }
    ownedWorktreePaths.insert(normalizedPath)
  }

  private func normalizedRepositoryPaths(_ paths: [String]) async -> [String] {
    var seen: Set<String> = []
    var normalizedPaths: [String] = []

    for path in paths {
      let normalizedPath = await normalizedRepositoryPath(for: path)
      guard seen.insert(normalizedPath).inserted else { continue }
      normalizedPaths.append(normalizedPath)
    }

    return normalizedPaths
  }

  private func upsertWorktree(_ worktree: WorktreeBranch, inRepositoryAt index: Int) {
    if let worktreeIndex = selectedRepositories[index].worktrees.firstIndex(where: { $0.path == worktree.path }) {
      let existing = selectedRepositories[index].worktrees[worktreeIndex]
      selectedRepositories[index].worktrees[worktreeIndex] = WorktreeBranch(
        name: worktree.name,
        path: worktree.path,
        isWorktree: worktree.isWorktree,
        sessions: worktree.sessions.isEmpty ? existing.sessions : worktree.sessions,
        isExpanded: existing.isExpanded || worktree.isExpanded
      )
    } else {
      selectedRepositories[index].worktrees.append(worktree)
    }
  }

  public func loadSessions(ids: Set<String>) async -> [CLISession] {
    guard !ids.isEmpty else { return [] }
    let files = CodexSessionFileScanner.listSessionFiles(codexDataPath: codexDataPath)
    var sessions: [CLISession] = []

    for path in files where ids.contains(where: { sessionId in
      URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.hasSuffix(sessionId)
    }) {
      guard let meta = CodexSessionFileScanner.readSessionMeta(from: path),
            ids.contains(meta.sessionId) else {
        continue
      }

      let summary = CodexSessionJSONLParser.parseSessionSummaryFile(at: path)
      let worktree = worktreeInfo(containing: meta.projectPath)
      let lastActivity = [summary.lastActivityAt, fileModificationDate(path)].compactMap { $0 }.max()
      let session = CLISession(
        id: meta.sessionId,
        projectPath: meta.projectPath,
        branchName: meta.branch ?? worktree.branchName,
        isWorktree: worktree.isWorktree,
        lastActivityAt: lastActivity ?? meta.startedAt ?? Date(),
        messageCount: summary.messageCount,
        isActive: isSessionFileActive(path),
        firstMessage: summary.firstUserMessage,
        lastMessage: summary.lastUserMessage,
        slug: nil,
        sessionFilePath: path
      )
      sessions.append(session)
    }

    return sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  public func loadLatestSessions(
    inWorktreePath worktreePath: String,
    excludingSessionIds: Set<String>,
    limit: Int
  ) async -> WorktreeSessionImportPage {
    guard limit > 0 else {
      return WorktreeSessionImportPage(sessions: [], hasMore: false)
    }

    let normalizedWorktreePath = WorktreeModuleResolver.normalizedDirectoryPath(worktreePath)
    let files = CodexSessionFileScanner.listSessionFiles(codexDataPath: codexDataPath)
    var sessions: [CLISession] = []

    for path in files {
      guard let meta = CodexSessionFileScanner.readSessionMeta(from: path),
            !excludingSessionIds.contains(meta.sessionId) else {
        continue
      }

      let projectPath = WorktreeModuleResolver.normalizedDirectoryPath(meta.projectPath)
      guard projectPath == normalizedWorktreePath || projectPath.hasPrefix(normalizedWorktreePath + "/") else {
        continue
      }

      let summary = CodexSessionJSONLParser.parseSessionSummaryFile(at: path)
      let worktree = worktreeInfo(containing: meta.projectPath)
      let lastActivity = [summary.lastActivityAt, meta.startedAt, fileModificationDate(path)].compactMap { $0 }.max()

      sessions.append(CLISession(
        id: meta.sessionId,
        projectPath: meta.projectPath,
        branchName: meta.branch ?? worktree.branchName,
        isWorktree: worktree.isWorktree,
        lastActivityAt: lastActivity ?? Date(),
        messageCount: summary.messageCount,
        isActive: isSessionFileActive(path),
        firstMessage: summary.firstUserMessage,
        lastMessage: summary.lastUserMessage,
        slug: nil,
        sessionFilePath: path
      ))
    }

    sessions.sort {
      if $0.lastActivityAt == $1.lastActivityAt {
        return $0.id < $1.id
      }
      return $0.lastActivityAt > $1.lastActivityAt
    }

    return WorktreeSessionImportPage(
      sessions: Array(sessions.prefix(limit)),
      hasMore: sessions.count > limit
    )
  }

  // MARK: - Session Scanning

  public func refreshSessions(skipWorktreeRedetection: Bool = false) async {
    guard !selectedRepositories.isEmpty else {
      repositoriesSubject.send([])
      return
    }

    if !skipWorktreeRedetection {
      let allWorktrees = await detectWorktreesBatch(
        repoPaths: selectedRepositories.map { $0.path }
      )

      for index in selectedRepositories.indices {
        let repoPath = selectedRepositories[index].path
        let detectedWorktrees = allWorktrees[repoPath] ?? []

        var merged: [WorktreeBranch] = []
        for detected in detectedWorktrees {
          if var existing = selectedRepositories[index].worktrees.first(where: { $0.path == detected.path }) {
            existing.name = detected.name
            existing.sessions = []
            merged.append(existing)
          } else {
            merged.append(detected)
          }
        }
        selectedRepositories[index].worktrees = merged
      }
    }

    let discoveryScope = makeSessionDiscoveryScope()

    let historyEntries = parseHistory()
    let historyBySession = Dictionary(grouping: historyEntries) { $0.sessionId }

    let sessionMetas = scanSessions(in: discoveryScope)

    var updatedRepositories = selectedRepositories
    var assignedSessionIds: Set<String> = []

    for repoIndex in updatedRepositories.indices {
      let orderedWorktreeIndices = updatedRepositories[repoIndex].worktrees.indices.sorted {
        updatedRepositories[repoIndex].worktrees[$0].path.count > updatedRepositories[repoIndex].worktrees[$1].path.count
      }

      for worktreeIndex in orderedWorktreeIndices {
        let worktree = updatedRepositories[repoIndex].worktrees[worktreeIndex]
        var sessions: [CLISession] = []

        for meta in sessionMetas {
          guard !assignedSessionIds.contains(meta.sessionId) else { continue }
          let matchesPath = meta.projectPath == worktree.path || meta.projectPath.hasPrefix(worktree.path + "/")
          guard matchesPath else { continue }

          let entries = historyBySession[meta.sessionId] ?? []
          let firstMessage = entries.first?.text
          let lastMessage = entries.last?.text
          let messageCount = entries.count

          let historyLast = entries.last?.date
          let lastActivityAt = [meta.lastActivityAt, historyLast].compactMap { $0 }.max()
          let isActive = isSessionFileActive(meta.sessionFilePath)

          let session = CLISession(
            id: meta.sessionId,
            projectPath: meta.projectPath,
            branchName: meta.branch ?? worktree.name,
            isWorktree: worktree.isWorktree,
            lastActivityAt: lastActivityAt ?? Date(),
            messageCount: messageCount,
            isActive: isActive,
            firstMessage: firstMessage,
            lastMessage: lastMessage,
            slug: nil,
            sessionFilePath: meta.sessionFilePath
          )

          sessions.append(session)
          assignedSessionIds.insert(meta.sessionId)
        }

        sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        updatedRepositories[repoIndex].worktrees[worktreeIndex].sessions = sessions
      }
    }

    selectedRepositories = updatedRepositories
    repositoriesSubject.send(selectedRepositories)
  }

  // MARK: - Helpers

  private struct CodexHistoryEntry: Decodable, Sendable {
    let sessionId: String
    let timestamp: Int64
    let text: String

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case timestamp = "ts"
      case text
    }

    var date: Date {
      Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
  }

  private struct CodexSessionInfo: Sendable {
    let sessionId: String
    let projectPath: String
    let branch: String?
    let sessionFilePath: String
    let lastActivityAt: Date?
  }

  private func parseHistory() -> [CodexHistoryEntry] {
    let historyPath = codexDataPath + "/history.jsonl"

    guard let data = FileManager.default.contents(atPath: historyPath),
          let content = String(data: data, encoding: .utf8) else {
      return []
    }

    let decoder = JSONDecoder()

    return content
      .components(separatedBy: .newlines)
      .compactMap { line -> CodexHistoryEntry? in
        guard !line.isEmpty,
              let jsonData = line.data(using: .utf8),
              let entry = try? decoder.decode(CodexHistoryEntry.self, from: jsonData) else {
          return nil
        }
        return entry
      }
  }

  private func scanSessions(in scope: SessionDiscoveryScope) -> [CodexSessionInfo] {
    let files = CodexSessionFileScanner.listSessionFiles(codexDataPath: codexDataPath)
    var results: [CodexSessionInfo] = []

    for path in files {
      guard let meta = CodexSessionFileScanner.readSessionMeta(from: path),
            scope.includes(projectPath: meta.projectPath, sessionId: meta.sessionId) else {
        continue
      }

      let lastActivity = fileModificationDate(path)

      results.append(CodexSessionInfo(
        sessionId: meta.sessionId,
        projectPath: meta.projectPath,
        branch: meta.branch,
        sessionFilePath: meta.sessionFilePath,
        lastActivityAt: lastActivity
      ))
    }

    return results
  }

  private func isSessionFileActive(_ path: String) -> Bool {
    guard let modDate = fileModificationDate(path) else { return false }
    return Date().timeIntervalSince(modDate) < 60
  }

  private func fileModificationDate(_ path: String) -> Date? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let modDate = attrs[.modificationDate] as? Date else {
      return nil
    }
    return modDate
  }

  private func worktreeInfo(containing projectPath: String) -> (branchName: String?, isWorktree: Bool) {
    let matchingWorktree = selectedRepositories
      .flatMap(\.worktrees)
      .filter { projectPath == $0.path || projectPath.hasPrefix($0.path + "/") }
      .max { $0.path.count < $1.path.count }

    return (matchingWorktree?.name, matchingWorktree?.isWorktree ?? false)
  }

  // MARK: - Worktree Detection

  private func detectWorktrees(at repoPath: String) async -> [WorktreeBranch] {
    let worktrees = await GitWorktreeDetector.listWorktrees(at: repoPath)

    if worktrees.isEmpty {
      ignoredWorktreePathsByRepository[repoPath] = []
      let info = await GitWorktreeDetector.detectWorktreeInfo(for: repoPath)
      return [
        WorktreeBranch(
          name: info?.branch ?? "main",
          path: repoPath,
          isWorktree: false,
          sessions: []
        )
      ]
    }

    let allWorktrees = worktrees.map { info in
      WorktreeBranch(
        name: info.branch ?? URL(fileURLWithPath: info.path).lastPathComponent,
        path: WorktreeModuleResolver.normalizedDirectoryPath(info.path),
        isWorktree: info.isWorktree,
        sessions: []
      )
    }

    ignoredWorktreePathsByRepository[repoPath] = Set(
      allWorktrees
        .filter { $0.isWorktree && !ownedWorktreePaths.contains($0.path) }
        .map(\.path)
    )

    return allWorktrees.filter { worktree in
      !worktree.isWorktree || ownedWorktreePaths.contains(worktree.path)
    }
  }

  private func detectWorktreesBatch(repoPaths: [String]) async -> [String: [WorktreeBranch]] {
    await withTaskGroup(of: (String, [WorktreeBranch]).self) { group in
      for repoPath in repoPaths {
        group.addTask {
          let worktrees = await self.detectWorktrees(at: repoPath)
          return (repoPath, worktrees)
        }
      }

      var results: [String: [WorktreeBranch]] = [:]
      for await (path, worktrees) in group {
        results[path] = worktrees
      }
      return results
    }
  }

  private func makeSessionDiscoveryScope() -> SessionDiscoveryScope {
    var repositoryPaths = Set<String>()
    var ownedPaths = Set<String>()
    for repo in selectedRepositories {
      repositoryPaths.insert(repo.path)
      for worktree in repo.worktrees where worktree.isWorktree {
        ownedPaths.insert(worktree.path)
      }
    }

    let ignoredPaths = ignoredWorktreePathsByRepository.values.reduce(into: Set<String>()) { result, paths in
      result.formUnion(paths)
    }

    return SessionDiscoveryScope(
      repositoryPaths: repositoryPaths,
      ownedWorktreePaths: ownedPaths.union(ownedWorktreePaths),
      ignoredWorktreePaths: ignoredPaths,
      focusedSessionIds: focusedSessionIds
    )
  }
}

// MARK: - Protocol Conformance

extension CodexSessionMonitorService: SessionMonitorServiceProtocol {}
