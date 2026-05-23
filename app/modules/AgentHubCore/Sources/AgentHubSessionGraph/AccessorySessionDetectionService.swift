//
//  AccessorySessionDetectionService.swift
//  AgentHub
//
//  Detects CLI sessions started from accessory terminal panes.
//

import Foundation

public struct AccessorySessionDetectionBaseline: Equatable, Sendable {
  public let provider: SessionProviderKind
  public let projectPath: String
  public let startedAt: Date
  public let knownSessionFiles: Set<String>

  public init(
    provider: SessionProviderKind,
    projectPath: String,
    startedAt: Date,
    knownSessionFiles: Set<String>
  ) {
    self.provider = provider
    self.projectPath = projectPath
    self.startedAt = startedAt
    self.knownSessionFiles = knownSessionFiles
  }
}

public struct AccessorySessionDetectionResult: Equatable, Sendable {
  public let provider: SessionProviderKind
  public let sessionId: String
  public let projectPath: String
  public let branchName: String?
  public let sessionFilePath: String?

  public init(
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    branchName: String?,
    sessionFilePath: String?
  ) {
    self.provider = provider
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.branchName = branchName
    self.sessionFilePath = sessionFilePath
  }
}

public protocol AccessorySessionDetectionServiceProtocol: Sendable {
  func makeBaseline(
    provider: SessionProviderKind,
    projectPath: String,
    startedAt: Date
  ) -> AccessorySessionDetectionBaseline

  func detectNewSession(
    provider: SessionProviderKind,
    projectPath: String,
    startedAt: Date,
    baseline: AccessorySessionDetectionBaseline
  ) -> AccessorySessionDetectionResult?
}

public struct AccessorySessionDetectionService: AccessorySessionDetectionServiceProtocol, @unchecked Sendable {
  private let claudeDataPath: String
  private let codexDataPath: String
  private let fileManager: FileManager

  public init(
    claudeDataPath: String = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude",
    codexDataPath: String = NSString(string: "~/.codex").expandingTildeInPath,
    fileManager: FileManager = .default
  ) {
    self.claudeDataPath = (claudeDataPath as NSString).expandingTildeInPath
    self.codexDataPath = (codexDataPath as NSString).expandingTildeInPath
    self.fileManager = fileManager
  }

  public func makeBaseline(
    provider: SessionProviderKind,
    projectPath: String,
    startedAt: Date
  ) -> AccessorySessionDetectionBaseline {
    AccessorySessionDetectionBaseline(
      provider: provider,
      projectPath: normalizedProjectPath(projectPath),
      startedAt: startedAt,
      knownSessionFiles: sessionFiles(provider: provider, projectPath: projectPath)
    )
  }

  public func detectNewSession(
    provider: SessionProviderKind,
    projectPath: String,
    startedAt: Date,
    baseline: AccessorySessionDetectionBaseline
  ) -> AccessorySessionDetectionResult? {
    let path = normalizedProjectPath(projectPath)
    let files = sessionFiles(provider: provider, projectPath: path)
    let candidates = files.subtracting(baseline.knownSessionFiles)

    switch provider {
    case .claude:
      return detectClaudeSession(in: candidates, projectPath: path, startedAt: startedAt)
    case .codex:
      return detectCodexSession(in: candidates, projectPath: path, startedAt: startedAt)
    }
  }

  private func sessionFiles(provider: SessionProviderKind, projectPath: String) -> Set<String> {
    switch provider {
    case .claude:
      let projectDir = claudeProjectDirectory(for: projectPath)
      let files = (try? fileManager.contentsOfDirectory(atPath: projectDir)) ?? []
      return Set(files.filter { $0.hasSuffix(".jsonl") }.map { "\(projectDir)/\($0)" })
    case .codex:
      return Set(CodexSessionFileScanner.listSessionFiles(codexDataPath: codexDataPath))
    }
  }

  private func detectClaudeSession(
    in files: Set<String>,
    projectPath: String,
    startedAt: Date
  ) -> AccessorySessionDetectionResult? {
    let cutoff = startedAt.addingTimeInterval(-2)
    var matches: [String] = []

    for path in files {
      guard let modifiedAt = fileActivityDate(path), modifiedAt >= cutoff else { continue }
      matches.append(path)
    }

    guard matches.count == 1, let path = matches.first else { return nil }
    let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard !sessionId.isEmpty else { return nil }
    return AccessorySessionDetectionResult(
      provider: .claude,
      sessionId: sessionId,
      projectPath: projectPath,
      branchName: URL(fileURLWithPath: projectPath).lastPathComponent,
      sessionFilePath: path
    )
  }

  private func detectCodexSession(
    in files: Set<String>,
    projectPath: String,
    startedAt: Date
  ) -> AccessorySessionDetectionResult? {
    let cutoff = startedAt.addingTimeInterval(-2)
    var matches: [CodexSessionMeta] = []

    for path in files {
      guard let modifiedAt = fileActivityDate(path), modifiedAt >= cutoff else { continue }
      guard let meta = CodexSessionFileScanner.readSessionMeta(from: path) else { continue }
      guard meta.projectPath == projectPath || meta.projectPath.hasPrefix(projectPath + "/") else { continue }
      matches.append(meta)
    }

    guard matches.count == 1, let meta = matches.first else { return nil }
    return AccessorySessionDetectionResult(
      provider: .codex,
      sessionId: meta.sessionId,
      projectPath: meta.projectPath,
      branchName: meta.branch,
      sessionFilePath: meta.sessionFilePath
    )
  }

  private func claudeProjectDirectory(for projectPath: String) -> String {
    "\(claudeDataPath)/projects/\(normalizedProjectPath(projectPath).claudeProjectPathEncoded)"
  }

  private func fileActivityDate(_ path: String) -> Date? {
    guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return nil }
    return (attrs[.modificationDate] as? Date) ?? (attrs[.creationDate] as? Date)
  }

  private func normalizedProjectPath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
  }
}
