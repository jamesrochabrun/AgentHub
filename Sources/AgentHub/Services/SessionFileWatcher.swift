//
//  SessionFileWatcher.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import Foundation
import Combine

// MARK: - SessionFileWatcher

/// Service that watches session JSONL files for real-time monitoring
public actor SessionFileWatcher {

  // MARK: - Types

  /// State update for a monitored session
  public struct StateUpdate: Sendable {
    public let sessionId: String
    public let state: SessionMonitorState
  }

  // MARK: - Properties

  private var watchedSessions: [String: FileWatcherInfo] = [:]
  private nonisolated let stateSubject = PassthroughSubject<StateUpdate, Never>()
  private let claudePath: String

  /// Serial queue for processing file events and status updates to prevent data races
  private nonisolated let processingQueue = DispatchQueue(label: "com.agenthub.sessionwatcher.processing")

  /// Seconds to wait before considering a tool as awaiting approval
  private var approvalTimeoutSeconds: Int = 5

  /// Publisher for state updates
  public nonisolated var statePublisher: AnyPublisher<StateUpdate, Never> {
    stateSubject.eraseToAnyPublisher()
  }

  // MARK: - Initialization

  public init(claudePath: String = "~/.claude") {
    self.claudePath = NSString(string: claudePath).expandingTildeInPath
    print("[SessionFileWatcher] init with path: \(self.claudePath)")
  }

  /// Set the approval timeout in seconds
  public func setApprovalTimeout(_ seconds: Int) {
    self.approvalTimeoutSeconds = max(1, seconds)  // Minimum 1 second
    print("[SessionFileWatcher] Approval timeout set to \(self.approvalTimeoutSeconds) seconds")
  }

  /// Get the current approval timeout in seconds
  public func getApprovalTimeout() -> Int {
    return approvalTimeoutSeconds
  }

  // MARK: - Public API

  /// Start monitoring a session
  public func startMonitoring(sessionId: String, projectPath: String) {
    print("[SessionFileWatcher] startMonitoring: \(sessionId)")

    // If already monitoring, just re-emit current state
    if let existingInfo = watchedSessions[sessionId] {
      print("[SessionFileWatcher] Already monitoring session, re-emitting state: \(sessionId)")
      let state = buildMonitorState(from: existingInfo.parseResult)
      stateSubject.send(StateUpdate(sessionId: sessionId, state: state))
      return
    }

    // Find session file
    let sessionFilePath = findSessionFile(sessionId: sessionId, projectPath: projectPath)
    guard let filePath = sessionFilePath else {
      print("[SessionFileWatcher] Could not find session file for: \(sessionId)")
      return
    }

    print("[SessionFileWatcher] Found session file: \(filePath)")

    // Initial parse
    var parseResult = SessionJSONLParser.parseSessionFile(at: filePath, approvalTimeoutSeconds: approvalTimeoutSeconds)
    let initialState = buildMonitorState(from: parseResult)

    // Emit initial state
    stateSubject.send(StateUpdate(sessionId: sessionId, state: initialState))

    // Set up file watching
    let fileDescriptor = open(filePath, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      print("[SessionFileWatcher] Could not open file for watching: \(filePath)")
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .extend],
      queue: DispatchQueue.global(qos: .utility)
    )

    // Track file position for incremental reading
    var filePosition = getFileSize(filePath)

    // Capture timeout for use in closures
    let timeout = approvalTimeoutSeconds

    // Shared state between closures - protected by processingQueue
    var lastFileEventTime = Date()
    var lastKnownFileSize = filePosition
    var lastEmittedStatus: SessionStatus = parseResult.currentStatus

    source.setEventHandler { [weak self] in
      guard let self = self else { return }

      self.processingQueue.async {
        // Record that we received a file event
        lastFileEventTime = Date()

        // Read new content
        let newLines = self.readNewLines(from: filePath, startingAt: &filePosition)

        // Update known file size
        lastKnownFileSize = filePosition

        guard !newLines.isEmpty else {
          print("[SessionFileWatcher] \(sessionId): file event but no new lines")
          return
        }

        print("[SessionFileWatcher] \(sessionId): \(newLines.count) new lines")

        // Parse new lines
        SessionJSONLParser.parseNewLines(newLines, into: &parseResult, approvalTimeoutSeconds: timeout)

        // Keep lastEmittedStatus in sync to prevent redundant emissions from status timer
        lastEmittedStatus = parseResult.currentStatus

        let updatedState = self.buildMonitorState(from: parseResult)

        // Emit update
        Task { @MainActor in
          self.stateSubject.send(StateUpdate(sessionId: sessionId, state: updatedState))
        }
      }
    }

    source.setCancelHandler {
      close(fileDescriptor)
    }

    source.resume()

    // Set up status timer to re-evaluate timeout-based status every second
    // Only emits updates when status actually changes
    let statusTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    statusTimer.schedule(deadline: .now() + 1, repeating: 1.0)

    statusTimer.setEventHandler { [weak self] in
      guard let self = self else { return }

      self.processingQueue.async {
        // Health check: detect stale file watcher
        let timeSinceLastEvent = Date().timeIntervalSince(lastFileEventTime)
        let currentFileSize = self.getFileSize(filePath)

        // If file has grown but no events in 5+ seconds, watcher may be stale
        if timeSinceLastEvent > 5 && currentFileSize > lastKnownFileSize {
          print("[SessionFileWatcher] ⚠️ Stale watcher detected for \(sessionId): file grew from \(lastKnownFileSize) to \(currentFileSize) but no events in \(Int(timeSinceLastEvent))s")

          // Recovery: re-read new content manually
          var tempPosition = lastKnownFileSize
          let newLines = self.readNewLines(from: filePath, startingAt: &tempPosition)

          if !newLines.isEmpty {
            print("[SessionFileWatcher] 🔄 Recovery: found \(newLines.count) missed lines, re-parsing...")
            SessionJSONLParser.parseNewLines(newLines, into: &parseResult, approvalTimeoutSeconds: timeout)

            // Update tracking
            lastKnownFileSize = tempPosition
            lastFileEventTime = Date()
          } else {
            // No new lines but file size changed - update tracking anyway
            lastKnownFileSize = currentFileSize
          }
        }

        // Re-evaluate status based on current time
        let previousStatus = lastEmittedStatus
        SessionJSONLParser.updateCurrentStatus(&parseResult, approvalTimeoutSeconds: timeout)

        // Only emit if status actually changed
        if parseResult.currentStatus != lastEmittedStatus {
          // Detect transition TO awaitingApproval (for notification)
          if case .awaitingApproval(let tool) = parseResult.currentStatus,
             !self.isAwaitingApproval(previousStatus) {
            // Get last user message for notification context
            let lastMessage = parseResult.recentActivities
              .last(where: { if case .userMessage = $0.type { return true }; return false })?
              .description

            // Send notification
            ApprovalNotificationService.shared.sendApprovalNotification(
              sessionId: sessionId,
              toolName: tool,
              projectPath: filePath,
              model: parseResult.model,
              lastMessage: lastMessage
            )
          }

          lastEmittedStatus = parseResult.currentStatus
          let updatedState = self.buildMonitorState(from: parseResult)

          Task { @MainActor in
            self.stateSubject.send(StateUpdate(sessionId: sessionId, state: updatedState))
          }
        }
      }
    }

    statusTimer.resume()

    // Store watcher info
    watchedSessions[sessionId] = FileWatcherInfo(
      filePath: filePath,
      source: source,
      statusTimer: statusTimer,
      parseResult: parseResult,
      lastFileEventTime: lastFileEventTime,
      lastKnownFileSize: lastKnownFileSize
    )

    print("[SessionFileWatcher] Started monitoring: \(sessionId)")
  }

  /// Stop monitoring a session
  public func stopMonitoring(sessionId: String) {
    print("[SessionFileWatcher] stopMonitoring: \(sessionId)")

    guard let info = watchedSessions.removeValue(forKey: sessionId) else {
      return
    }

    info.source.cancel()
    info.statusTimer.cancel()
    print("[SessionFileWatcher] Stopped monitoring: \(sessionId)")
  }

  /// Get current state for a session
  public func getState(sessionId: String) -> SessionMonitorState? {
    guard let info = watchedSessions[sessionId] else { return nil }
    return buildMonitorState(from: info.parseResult)
  }

  /// Check if a session is being monitored
  public func isMonitoring(sessionId: String) -> Bool {
    watchedSessions[sessionId] != nil
  }

  /// Force refresh a session's state
  public func refreshState(sessionId: String) {
    guard let info = watchedSessions[sessionId] else { return }

    let parseResult = SessionJSONLParser.parseSessionFile(at: info.filePath, approvalTimeoutSeconds: approvalTimeoutSeconds)
    watchedSessions[sessionId]?.parseResult = parseResult

    let state = buildMonitorState(from: parseResult)
    stateSubject.send(StateUpdate(sessionId: sessionId, state: state))
  }

  // MARK: - Private Helpers

  private func findSessionFile(sessionId: String, projectPath: String) -> String? {
    // Session files are in: ~/.claude/projects/{encoded-path}/{sessionId}.jsonl
    let encodedPath = projectPath.replacingOccurrences(of: "/", with: "-")
    let projectsDir = "\(claudePath)/projects/\(encodedPath)"
    let sessionFile = "\(projectsDir)/\(sessionId).jsonl"

    print("[SessionFileWatcher] Looking for: \(sessionFile)")

    if FileManager.default.fileExists(atPath: sessionFile) {
      return sessionFile
    }

    // Try alternative encodings
    let alternativeEncodings = [
      projectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "",
      projectPath.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "~", with: "-")
    ]

    for encoded in alternativeEncodings {
      let altPath = "\(claudePath)/projects/\(encoded)/\(sessionId).jsonl"
      if FileManager.default.fileExists(atPath: altPath) {
        return altPath
      }
    }

    // Search in projects directory
    let projectsDirPath = "\(claudePath)/projects"
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: projectsDirPath) {
      for dir in contents {
        let potentialFile = "\(projectsDirPath)/\(dir)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: potentialFile) {
          return potentialFile
        }
      }
    }

    return nil
  }

  private nonisolated func getFileSize(_ path: String) -> UInt64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? UInt64 else {
      return 0
    }
    return size
  }

  private nonisolated func readNewLines(from path: String, startingAt position: inout UInt64) -> [String] {
    guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? handle.close() }

    let currentSize = getFileSize(path)
    guard currentSize > position else { return [] }

    do {
      try handle.seek(toOffset: position)
      let data = handle.readDataToEndOfFile()
      position = currentSize

      guard let content = String(data: data, encoding: .utf8) else { return [] }
      return content.components(separatedBy: .newlines).filter { !$0.isEmpty }
    } catch {
      print("[SessionFileWatcher] Error reading new lines: \(error)")
      return []
    }
  }

  private nonisolated func buildMonitorState(from result: SessionJSONLParser.ParseResult) -> SessionMonitorState {
    // Convert pending tool uses
    let pendingToolUse: PendingToolUse?
    if let (_, pending) = result.pendingToolUses.first {
      pendingToolUse = PendingToolUse(
        toolName: pending.toolName,
        toolUseId: pending.toolUseId,
        timestamp: pending.timestamp,
        input: pending.input
      )
    } else {
      pendingToolUse = nil
    }

    return SessionMonitorState(
      status: result.currentStatus,
      currentTool: extractCurrentTool(from: result),
      lastActivityAt: result.lastActivityAt ?? Date(),
      inputTokens: result.lastInputTokens,          // Last input (context window)
      outputTokens: result.lastOutputTokens,         // Last output
      totalOutputTokens: result.totalOutputTokens,   // Accumulated (for cost)
      cacheReadTokens: result.cacheReadTokens,
      cacheCreationTokens: result.cacheCreationTokens,
      messageCount: result.messageCount,
      toolCalls: result.toolCalls,
      sessionStartedAt: result.sessionStartedAt,
      model: result.model,
      gitBranch: result.gitBranch,
      pendingToolUse: pendingToolUse,
      recentActivities: result.recentActivities
    )
  }

  private nonisolated func extractCurrentTool(from result: SessionJSONLParser.ParseResult) -> String? {
    if let (_, pending) = result.pendingToolUses.first {
      return pending.toolName
    }
    return nil
  }

  /// Check if a status is awaitingApproval
  private nonisolated func isAwaitingApproval(_ status: SessionStatus) -> Bool {
    if case .awaitingApproval = status { return true }
    return false
  }
}

// MARK: - FileWatcherInfo

private struct FileWatcherInfo {
  let filePath: String
  let source: DispatchSourceFileSystemObject
  let statusTimer: DispatchSourceTimer
  var parseResult: SessionJSONLParser.ParseResult

  // Health check tracking
  var lastFileEventTime: Date
  var lastKnownFileSize: UInt64
}
