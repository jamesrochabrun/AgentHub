//
//  CodexSessionFileWatcher.swift
//  AgentHub
//
//  Watches Codex session JSONL files for real-time monitoring.
//

import Combine
import Foundation
import os

public actor CodexSessionFileWatcher {

  // MARK: - Properties

  private var watchedSessions: [String: FileWatcherInfo] = [:]
  private nonisolated let stateSubject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  private let codexPath: String
  private nonisolated let processingQueue = DispatchQueue(label: "com.agenthub.codexwatcher.processing")
  private var approvalTimeoutSeconds: Int = 0

  public nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    stateSubject.eraseToAnyPublisher()
  }

  public init(codexPath: String = "~/.codex") {
    self.codexPath = NSString(string: codexPath).expandingTildeInPath
  }

  public func setApprovalTimeout(_ seconds: Int) async {
    self.approvalTimeoutSeconds = max(1, seconds)
  }

  public func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String? = nil) async {
    if let existing = watchedSessions[sessionId] {
      let state = buildMonitorState(from: existing.parseResult)
      stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: state))
      return
    }

    let filePath = sessionFilePath ?? findSessionFile(sessionId: sessionId)
    guard let filePath else {
      AppLogger.watcher.error("[Codex] Could not find session file for: \(sessionId)")
      return
    }

    var parseResult = CodexSessionJSONLParser.parseSessionFile(
      at: filePath,
      approvalTimeoutSeconds: approvalTimeoutSeconds
    )
    let initialState = buildMonitorState(from: parseResult)
    stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: initialState))

    let fileDescriptor = open(filePath, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      AppLogger.watcher.error("[Codex] Could not open file for watching: \(filePath)")
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .extend],
      queue: DispatchQueue.global(qos: .utility)
    )

    var filePosition = getFileSize(filePath)
    let timeout = approvalTimeoutSeconds
    var lastFileEventTime = Date()
    var lastKnownFileSize = filePosition
    var lastEmittedStatus: SessionStatus = parseResult.currentStatus

    source.setEventHandler { [weak self] in
      guard let self else { return }
      self.processingQueue.async {
        lastFileEventTime = Date()
        let newLines = self.readNewLines(from: filePath, startingAt: &filePosition)
        lastKnownFileSize = filePosition
        guard !newLines.isEmpty else { return }
        CodexSessionJSONLParser.parseNewLines(newLines, into: &parseResult, approvalTimeoutSeconds: timeout)
        lastEmittedStatus = parseResult.currentStatus

        let updatedState = self.buildMonitorState(from: parseResult)
        Task { @MainActor in
          self.stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: updatedState))
        }
      }
    }

    source.setCancelHandler {
      close(fileDescriptor)
    }

    source.resume()

    let statusTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    statusTimer.schedule(deadline: .now() + 1.5, repeating: 1.5)
    statusTimer.setEventHandler { [weak self] in
      guard let self else { return }
      self.processingQueue.async {
        let timeSinceLastEvent = Date().timeIntervalSince(lastFileEventTime)
        let currentFileSize = self.getFileSize(filePath)

        if timeSinceLastEvent > 5 && currentFileSize > lastKnownFileSize {
          var tempPosition = lastKnownFileSize
          let newLines = self.readNewLines(from: filePath, startingAt: &tempPosition)
          if !newLines.isEmpty {
            CodexSessionJSONLParser.parseNewLines(newLines, into: &parseResult, approvalTimeoutSeconds: timeout)
            lastKnownFileSize = tempPosition
            lastFileEventTime = Date()
          } else {
            lastKnownFileSize = currentFileSize
          }
        }

        let previousStatus = lastEmittedStatus
        CodexSessionJSONLParser.updateCurrentStatus(&parseResult, approvalTimeoutSeconds: timeout)

        if parseResult.currentStatus != lastEmittedStatus {
          lastEmittedStatus = parseResult.currentStatus
          let updatedState = self.buildMonitorState(from: parseResult)

          Task { @MainActor in
            self.stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: updatedState))
          }
        } else if previousStatus != parseResult.currentStatus {
          lastEmittedStatus = parseResult.currentStatus
        }
      }
    }
    statusTimer.resume()

    watchedSessions[sessionId] = FileWatcherInfo(
      filePath: filePath,
      source: source,
      statusTimer: statusTimer,
      parseResult: parseResult,
      lastFileEventTime: lastFileEventTime,
      lastKnownFileSize: lastKnownFileSize
    )
  }

  public func stopMonitoring(sessionId: String) async {
    guard let info = watchedSessions.removeValue(forKey: sessionId) else { return }
    info.source.cancel()
    info.statusTimer.cancel()
  }

  public func getState(sessionId: String) async -> SessionMonitorState? {
    guard let info = watchedSessions[sessionId] else { return nil }
    return buildMonitorState(from: info.parseResult)
  }

  public func refreshState(sessionId: String) async {
    guard let info = watchedSessions[sessionId] else { return }
    let parseResult = CodexSessionJSONLParser.parseSessionFile(
      at: info.filePath,
      approvalTimeoutSeconds: approvalTimeoutSeconds
    )
    watchedSessions[sessionId]?.parseResult = parseResult
    let state = buildMonitorState(from: parseResult)
    stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: state))
  }

  // MARK: - Helpers

  private func findSessionFile(sessionId: String) -> String? {
    let sessionsRoot = codexPath + "/sessions"
    guard let enumerator = FileManager.default.enumerator(atPath: sessionsRoot) else { return nil }
    for case let file as String in enumerator {
      guard file.hasSuffix(".jsonl") else { continue }
      if file.contains(sessionId) {
        return sessionsRoot + "/" + file
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
      return []
    }
  }

  private nonisolated func buildMonitorState(from result: CodexSessionJSONLParser.ParseResult) -> SessionMonitorState {
    return SessionMonitorState(
      status: result.currentStatus,
      currentTool: result.pendingToolUses.first?.value.toolName,
      lastActivityAt: result.lastActivityAt ?? Date(),
      inputTokens: result.lastInputTokens,
      outputTokens: result.lastOutputTokens,
      totalOutputTokens: result.totalOutputTokens,
      cacheReadTokens: result.cacheReadTokens,
      cacheCreationTokens: result.cacheCreationTokens,
      messageCount: result.messageCount,
      toolCalls: result.toolCalls,
      sessionStartedAt: result.sessionStartedAt,
      model: result.model,
      gitBranch: nil,
      pendingToolUse: nil,
      recentActivities: result.recentActivities
    )
  }
}

// MARK: - FileWatcherInfo

private struct FileWatcherInfo {
  let filePath: String
  let source: DispatchSourceFileSystemObject
  let statusTimer: DispatchSourceTimer
  var parseResult: CodexSessionJSONLParser.ParseResult

  var lastFileEventTime: Date
  var lastKnownFileSize: UInt64
}

// MARK: - Protocol Conformance

extension CodexSessionFileWatcher: SessionFileWatcherProtocol {}
