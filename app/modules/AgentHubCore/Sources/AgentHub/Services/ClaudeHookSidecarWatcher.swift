import Combine
import Foundation
import os

// MARK: - SidecarUpdate

/// Emitted whenever an `approvals/{sessionId}.jsonl` file yields new state.
public struct SidecarUpdate: Sendable {
  public let sessionId: String
  /// The latest pending info, or `nil` if the last event was `resolved`
  /// (or there are no pending events).
  public let info: SessionJSONLParser.PendingToolInfo?

  public init(sessionId: String, info: SessionJSONLParser.PendingToolInfo?) {
    self.sessionId = sessionId
    self.info = info
  }
}

// MARK: - ClaudeHookSidecarWatcherProtocol

public protocol ClaudeHookSidecarWatcherProtocol: AnyObject, Sendable {
  var updates: AnyPublisher<SidecarUpdate, Never> { get }
  func startWatching(sessionId: String) async
  func stopWatching(sessionId: String) async
  func pendingInfo(for sessionId: String) async -> SessionJSONLParser.PendingToolInfo?
  /// Remove every sidecar file on disk and drop all in-memory state. Called
  /// at app launch and termination so stale `pending` entries left behind by
  /// an approval the user resolved while AgentHub was down can't be replayed
  /// as false `awaitingApproval` state on the next launch.
  func wipeAll() async
}

// MARK: - ClaudeHookSidecarWatcher

/// Watches the approvals sidecar directory populated by the installed hook
/// script. Produces `PendingToolInfo` values that `SessionFileWatcher` merges
/// into its `ParseResult.pendingToolUses` before building monitor state — so
/// that approval-pending tools surface in the UI before the JSONL turn commits.
public actor ClaudeHookSidecarWatcher: ClaudeHookSidecarWatcherProtocol {

  private let approvalsDirectory: URL
  private let fileManager: FileManager
  private nonisolated let subject = PassthroughSubject<SidecarUpdate, Never>()
  private nonisolated let processingQueue = DispatchQueue(label: "com.agenthub.approvals.sidecar")

  private var watchedSessions: Set<String> = []
  private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
  private var filePositions: [String: UInt64] = [:]
  private var currentInfo: [String: SessionJSONLParser.PendingToolInfo] = [:]
  private var directorySource: DispatchSourceFileSystemObject?

  public nonisolated var updates: AnyPublisher<SidecarUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  public init(
    approvalsDirectory: URL = ClaudeHookPaths.approvalsDirectoryURL,
    fileManager: FileManager = .default
  ) {
    self.approvalsDirectory = approvalsDirectory
    self.fileManager = fileManager
  }

  // MARK: - Public API

  public func startWatching(sessionId: String) async {
    guard !sessionId.isEmpty, !watchedSessions.contains(sessionId) else { return }
    watchedSessions.insert(sessionId)

    ensureDirectory()
    startDirectorySourceIfNeeded()

    // Process any pre-existing content (hook may have fired before we started
    // watching this session).
    attachFileSource(for: sessionId)
    processFile(sessionId: sessionId)
  }

  public func stopWatching(sessionId: String) async {
    guard watchedSessions.contains(sessionId) else { return }
    watchedSessions.remove(sessionId)

    if let source = fileSources[sessionId] {
      source.cancel()
    }
    fileSources.removeValue(forKey: sessionId)
    filePositions.removeValue(forKey: sessionId)
    currentInfo.removeValue(forKey: sessionId)

    // Intentionally keep the sidecar file on disk. `stopWatching` is also
    // called when a user toggles monitoring off mid-approval (the JSONL
    // hasn't flushed the `tool_use` yet), so the sidecar is the only
    // persisted record of the pending event. If monitoring is turned back
    // on while the tool is still awaiting approval, `startWatching` needs
    // to find it. Cross-restart staleness is handled by `wipeAll` at
    // launch/terminate; see plans/parsed-weaving-nebula.md.
  }

  public func pendingInfo(for sessionId: String) async -> SessionJSONLParser.PendingToolInfo? {
    currentInfo[sessionId]
  }

  public func wipeAll() async {
    directorySource?.cancel()
    directorySource = nil
    for (_, source) in fileSources { source.cancel() }
    fileSources.removeAll()
    filePositions.removeAll()
    currentInfo.removeAll()
    watchedSessions.removeAll()

    if fileManager.fileExists(atPath: approvalsDirectory.path) {
      try? fileManager.removeItem(at: approvalsDirectory)
    }
    ensureDirectory()
  }

  // MARK: - Internals

  private func ensureDirectory() {
    try? fileManager.createDirectory(at: approvalsDirectory, withIntermediateDirectories: true)
  }

  private func startDirectorySourceIfNeeded() {
    guard directorySource == nil else { return }
    let fd = open(approvalsDirectory.path, O_EVTONLY)
    guard fd >= 0 else {
      AppLogger.watcher.error("[SidecarWatcher] Could not open approvals dir: \(self.approvalsDirectory.path)")
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .rename],
      queue: processingQueue
    )
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.handleDirectoryEvent() }
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    directorySource = source
  }

  private func handleDirectoryEvent() async {
    // A new sidecar file may have been created. Attach sources for any watched
    // session that didn't previously have one, then drain.
    for sessionId in watchedSessions where fileSources[sessionId] == nil {
      attachFileSource(for: sessionId)
    }
    for sessionId in watchedSessions {
      processFile(sessionId: sessionId)
    }
  }

  private func attachFileSource(for sessionId: String) {
    let fileURL = approvalsDirectory.appendingPathComponent("\(sessionId).jsonl")
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    guard fileSources[sessionId] == nil else { return }

    let fd = open(fileURL.path, O_EVTONLY)
    guard fd >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .delete, .rename],
      queue: processingQueue
    )
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.processFile(sessionId: sessionId) }
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    fileSources[sessionId] = source
  }

  /// Reads new bytes from the session's sidecar, parses each JSON line, updates
  /// `currentInfo`, and emits an update if state changed.
  private func processFile(sessionId: String) {
    let fileURL = approvalsDirectory.appendingPathComponent("\(sessionId).jsonl")
    guard fileManager.fileExists(atPath: fileURL.path) else { return }

    var position = filePositions[sessionId] ?? 0
    guard let lines = readNewLines(from: fileURL, startingAt: &position) else { return }
    filePositions[sessionId] = position
    guard !lines.isEmpty else { return }

    var changed = false
    for line in lines {
      guard let data = line.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(SidecarLine.self, from: data) else {
        continue
      }
      switch decoded.event {
      case "pending":
        let info = SessionJSONLParser.PendingToolInfo(
          toolName: decoded.toolName ?? "",
          toolUseId: decoded.toolUseId ?? "hook-\(sessionId)",
          timestamp: decoded.parsedTimestamp ?? Date(),
          input: decoded.inputPreview,
          codeChangeInput: decoded.codeChangeInput
        )
        currentInfo[sessionId] = info
        changed = true
      case "resolved":
        if currentInfo.removeValue(forKey: sessionId) != nil {
          changed = true
        }
      default:
        continue
      }
    }

    if changed {
      let info = currentInfo[sessionId]
      subject.send(SidecarUpdate(sessionId: sessionId, info: info))
    }
  }

  private func readNewLines(from url: URL, startingAt position: inout UInt64) -> [String]? {
    guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
    defer { try? handle.close() }

    let size: UInt64
    do {
      let attrs = try fileManager.attributesOfItem(atPath: url.path)
      size = (attrs[.size] as? UInt64) ?? 0
    } catch {
      return nil
    }

    // If the file shrank (rotated/truncated), reset.
    if size < position {
      position = 0
    }
    guard size > position else { return [] }

    do {
      try handle.seek(toOffset: position)
      let data = handle.readDataToEndOfFile()
      position = size
      guard let content = String(data: data, encoding: .utf8) else { return [] }
      return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    } catch {
      return nil
    }
  }

  deinit {
    directorySource?.cancel()
    for (_, source) in fileSources { source.cancel() }
  }
}

// MARK: - SidecarLine

private struct SidecarLine: Decodable {
  let event: String
  let toolName: String?
  let toolUseId: String?
  let timestamp: String?
  let input: InputPayload?

  var parsedTimestamp: Date? {
    guard let timestamp else { return nil }
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: timestamp)
  }

  var inputPreview: String? {
    guard let input else { return nil }
    if let filePath = input.filePath {
      return URL(fileURLWithPath: filePath).lastPathComponent
    }
    if let command = input.command {
      return String(command.prefix(60))
    }
    if let url = input.url {
      return url
    }
    return nil
  }

  var codeChangeInput: CodeChangeInput? {
    guard let input, let filePath = input.filePath else { return nil }
    guard let tool = toolName else { return nil }
    switch tool {
    case "Edit":
      return CodeChangeInput(
        toolType: .edit,
        filePath: filePath,
        oldString: input.oldString,
        newString: input.newString,
        replaceAll: input.replaceAll
      )
    case "Write":
      // The existing pipeline expects Write's full content in `newString`
      // (see CodeChangeInput.toToolParameters for `.write`).
      return CodeChangeInput(
        toolType: .write,
        filePath: filePath,
        newString: input.content
      )
    case "MultiEdit":
      let editsPairs: [[String: String]]? = input.edits?.compactMap { e in
        guard let oldString = e.oldString, let newString = e.newString else { return nil }
        return ["old_string": oldString, "new_string": newString]
      }
      return CodeChangeInput(
        toolType: .multiEdit,
        filePath: filePath,
        edits: editsPairs
      )
    default:
      return nil
    }
  }
}

private struct InputPayload: Decodable {
  let filePath: String?
  let oldString: String?
  let newString: String?
  let replaceAll: Bool?
  let content: String?
  let command: String?
  let url: String?
  let edits: [EditEntry]?

  enum CodingKeys: String, CodingKey {
    case filePath = "file_path"
    case oldString = "old_string"
    case newString = "new_string"
    case replaceAll = "replace_all"
    case content
    case command
    case url
    case edits
  }
}

private struct EditEntry: Decodable {
  let oldString: String?
  let newString: String?

  enum CodingKeys: String, CodingKey {
    case oldString = "old_string"
    case newString = "new_string"
  }
}
