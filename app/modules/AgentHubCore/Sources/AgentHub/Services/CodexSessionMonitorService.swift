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

  // MARK: - Initialization

  public init(codexDataPath: String? = nil, metadataStore: SessionMetadataStore? = nil) {
    self.codexDataPath = codexDataPath ?? (NSHomeDirectory() + "/.codex")
    self.metadataStore = metadataStore
  }

  // MARK: - Repository Management

  @discardableResult
  public func addRepository(_ path: String) async -> SelectedRepository? {
    guard !selectedRepositories.contains(where: { $0.path == path }) else {
      return selectedRepositories.first { $0.path == path }
    }

    let worktrees = await detectWorktrees(at: path)
    let repository = SelectedRepository(
      path: path,
      worktrees: worktrees,
      isExpanded: true
    )

    selectedRepositories.append(repository)
    await refreshSessions(skipWorktreeRedetection: true)
    return repository
  }

  public func removeRepository(_ path: String) async {
    selectedRepositories.removeAll { $0.path == path }
    repositoriesSubject.send(selectedRepositories)
  }

  public func getSelectedRepositories() async -> [SelectedRepository] {
    selectedRepositories
  }

  public func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    selectedRepositories = repositories
    await refreshSessions()
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

    let allPaths = getAllMonitoredPaths()

    let historyEntries = parseHistory()
    let historyBySession = Dictionary(grouping: historyEntries) { $0.sessionId }

    let sessionMetas = scanSessions(for: allPaths)

    var updatedRepositories = selectedRepositories
    var assignedSessionIds: Set<String> = []

    for repoIndex in updatedRepositories.indices {
      for worktreeIndex in updatedRepositories[repoIndex].worktrees.indices {
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

  private func scanSessions(for paths: Set<String>) -> [CodexSessionInfo] {
    let files = CodexSessionFileScanner.listSessionFiles(codexDataPath: codexDataPath)
    var results: [CodexSessionInfo] = []

    for path in files {
      guard let meta = CodexSessionFileScanner.readSessionMeta(from: path) else { continue }

      let matchesPath = paths.contains { p in
        meta.projectPath == p || meta.projectPath.hasPrefix(p + "/")
      }
      guard matchesPath else { continue }

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

  // MARK: - Worktree Detection

  private func detectWorktrees(at repoPath: String) async -> [WorktreeBranch] {
    let worktrees = await GitWorktreeDetector.listWorktrees(at: repoPath)

    if worktrees.isEmpty {
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

    return worktrees.map { info in
      WorktreeBranch(
        name: info.branch ?? URL(fileURLWithPath: info.path).lastPathComponent,
        path: info.path,
        isWorktree: info.isWorktree,
        sessions: []
      )
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

  private func getAllMonitoredPaths() -> Set<String> {
    var paths = Set<String>()
    for repo in selectedRepositories {
      paths.insert(repo.path)
      for worktree in repo.worktrees {
        paths.insert(worktree.path)
      }
    }
    return paths
  }
}

// MARK: - Protocol Conformance

extension CodexSessionMonitorService: SessionMonitorServiceProtocol {}
