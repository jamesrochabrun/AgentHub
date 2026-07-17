//
//  WorkspaceSessionProcessProviderResolver.swift
//  AgentHub
//

import Foundation

public protocol WorkspaceSessionProcessProviderResolving: Sendable {
  func provider(
    for processID: Int32,
    executableNames: [SessionProviderKind: String]
  ) async -> SessionProviderKind?
}

/// Identifies the CLI currently running in a terminal from its foreground PID.
/// Results are cached by PID because a process cannot change its executable.
public actor WorkspaceSessionProcessProviderResolver: WorkspaceSessionProcessProviderResolving {
  private enum CachedProvider: Sendable {
    case provider(SessionProviderKind)
    case unsupported

    var resolvedProvider: SessionProviderKind? {
      switch self {
      case .provider(let provider): provider
      case .unsupported: nil
      }
    }
  }

  private let processInspector: any ProcessInspecting
  private var cache: [Int32: CachedProvider] = [:]

  public init() {
    processInspector = DarwinProcessInspector()
  }

  init(processInspector: any ProcessInspecting) {
    self.processInspector = processInspector
  }

  public func provider(
    for processID: Int32,
    executableNames: [SessionProviderKind: String]
  ) async -> SessionProviderKind? {
    guard processID > 0 else { return nil }
    if let cached = cache[processID] {
      return cached.resolvedProvider
    }

    let commandLine = await processInspector.identity(for: processID)?.commandLine
    let provider = commandLine.flatMap {
      Self.provider(from: $0, executableNames: executableNames)
    }
    cache[processID] = provider.map(CachedProvider.provider) ?? .unsupported
    if cache.count > 512 {
      cache.removeAll(keepingCapacity: true)
    }
    return provider
  }

  static func provider(
    from commandLine: String,
    executableNames: [SessionProviderKind: String]
  ) -> SessionProviderKind? {
    let normalizedCommand = commandLine.lowercased()
    let matches = SessionProviderKind.allCases.filter { provider in
      let configuredExecutable = executableNames[provider]
        .map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
      let signatures = [configuredExecutable, provider == .claude ? "claude" : "codex"]
        .compactMap { $0 }
      return signatures.contains { signature in
        normalizedCommand.range(
          of: "(^|[/[:space:]])\(NSRegularExpression.escapedPattern(for: signature))([[:space:]]|$)",
          options: .regularExpression
        ) != nil
      }
    }
    return matches.count == 1 ? matches[0] : nil
  }
}
