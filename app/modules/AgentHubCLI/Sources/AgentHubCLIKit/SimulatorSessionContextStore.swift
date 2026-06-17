import Foundation

public struct SimulatorSessionContext: Codable, Equatable, Identifiable, Sendable {
  public let provider: WorktreeLaunchProvider?
  public let sessionId: String?
  public let projectPath: String
  public let udid: String
  public let deviceName: String?
  public let runtimeName: String?
  public let isBooted: Bool
  public let displayMode: String?
  public let panelVisible: Bool
  public let updatedAt: Date

  public init(
    provider: WorktreeLaunchProvider?,
    sessionId: String?,
    projectPath: String,
    udid: String,
    deviceName: String?,
    runtimeName: String?,
    isBooted: Bool,
    displayMode: String?,
    panelVisible: Bool = true,
    updatedAt: Date = Date()
  ) {
    self.provider = provider
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.udid = udid
    self.deviceName = deviceName
    self.runtimeName = runtimeName
    self.isBooted = isBooted
    self.displayMode = displayMode
    self.panelVisible = panelVisible
    self.updatedAt = updatedAt
  }

  public var id: String {
    [
      provider?.commandLineValue ?? "unknown",
      sessionId ?? "",
      projectPath,
      udid
    ].joined(separator: "|")
  }
}

public struct SimulatorSessionContextStore: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL = SimulatorSessionContextStore.defaultDirectoryURL()) {
    self.directoryURL = directoryURL
  }

  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("simulator-context", isDirectory: true)
  }

  public func write(_ context: SimulatorSessionContext) throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(context)

    let finalURL = fileURL(
      provider: context.provider,
      sessionId: context.sessionId,
      projectPath: context.projectPath
    )
    let temporaryURL = directoryURL
      .appendingPathComponent(".\(finalURL.deletingPathExtension().lastPathComponent).tmp", isDirectory: false)

    try data.write(to: temporaryURL, options: [.atomic])
    if FileManager.default.fileExists(atPath: finalURL.path) {
      try FileManager.default.removeItem(at: finalURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
  }

  public func remove(
    provider: WorktreeLaunchProvider?,
    sessionId: String?,
    projectPath: String
  ) throws {
    let url = fileURL(provider: provider, sessionId: sessionId, projectPath: projectPath)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  public func context(
    provider: WorktreeLaunchProvider?,
    sessionId: String?,
    projectPath: String
  ) throws -> SimulatorSessionContext? {
    let url = fileURL(provider: provider, sessionId: sessionId, projectPath: projectPath)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    return try decoder.decode(SimulatorSessionContext.self, from: data)
  }

  public func contexts() throws -> [SimulatorSessionContext] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else {
      return []
    }

    let files = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    )

    return files
      .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
      .compactMap { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SimulatorSessionContext.self, from: data)
      }
      .sorted {
        if $0.updatedAt == $1.updatedAt {
          return $0.id < $1.id
        }
        return $0.updatedAt > $1.updatedAt
      }
  }

  public func resolveContext(
    provider: WorktreeLaunchProvider?,
    sessionId: String?,
    projectPath: String?
  ) throws -> SimulatorSessionContext? {
    let allContexts = try contexts()
    if let sessionId, !sessionId.isEmpty {
      let exact = allContexts.first { context in
        context.sessionId == sessionId
          && (provider == nil || context.provider == provider)
          && (projectPath == nil || normalizedPath(context.projectPath) == normalizedPath(projectPath ?? ""))
      }
      if let exact { return exact }
    }

    if let projectPath, !projectPath.isEmpty {
      let normalizedProject = normalizedPath(projectPath)
      return allContexts.first { context in
        context.panelVisible && normalizedPath(context.projectPath) == normalizedProject
      }
    }

    return allContexts.first { $0.panelVisible }
  }

  public func fileURL(
    provider: WorktreeLaunchProvider?,
    sessionId: String?,
    projectPath: String
  ) -> URL {
    directoryURL.appendingPathComponent(
      "\(fileStem(provider: provider, sessionId: sessionId, projectPath: projectPath)).json",
      isDirectory: false
    )
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private func fileStem(
    provider: WorktreeLaunchProvider?,
    sessionId: String?,
    projectPath: String
  ) -> String {
    let key = [
      provider?.commandLineValue ?? "unknown",
      sessionId ?? "",
      normalizedPath(projectPath)
    ].joined(separator: "|")
    return Data(key.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
  }

  private func normalizedPath(_ path: String) -> String {
    var normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL
      .path
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }
}
