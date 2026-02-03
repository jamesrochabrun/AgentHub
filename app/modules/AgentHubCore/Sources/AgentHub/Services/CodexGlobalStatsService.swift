//
//  CodexGlobalStatsService.swift
//  AgentHub
//
//  Service that aggregates global Codex usage statistics from session JSONL files.
//

import Foundation
import Observation
import os

// MARK: - CodexGlobalStatsService

/// Service that monitors and provides global Codex usage statistics
/// by aggregating data from all session JSONL files in ~/.codex/sessions/
@Observable
public final class CodexGlobalStatsService: @unchecked Sendable {

  // MARK: - Properties

  /// Total tokens across all sessions (input + output)
  public private(set) var totalTokens: Int = 0

  /// Total number of session files
  public private(set) var totalSessions: Int = 0

  /// Total messages across all sessions
  public private(set) var totalMessages: Int = 0

  /// Model usage statistics grouped by model name
  public private(set) var modelStats: [String: CodexModelUsage] = [:]

  /// Whether stats are available (sessions directory exists)
  public private(set) var isAvailable: Bool = false

  /// Whether stats are currently loading
  public private(set) var isLoading: Bool = false

  /// Last time stats were updated
  public private(set) var lastUpdated: Date?

  private let sessionsDirectoryPath: String
  private var directoryWatcher: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1
  private var isLoadingInProgress = false
  private var pendingReload = false
  private var debounceWorkItem: DispatchWorkItem?
  private var loadingTask: Task<Void, Never>?

  // MARK: - Computed Properties

  /// Formatted total tokens (e.g., "10.5M", "150K")
  public var formattedTotalTokens: String {
    formatTokenCount(totalTokens)
  }

  /// Model-specific stats sorted by token count
  public var sortedModelStats: [(name: String, usage: CodexModelUsage)] {
    modelStats.map { (name: formatModelName($0.key), usage: $0.value) }
      .sorted { $0.usage.totalTokens > $1.usage.totalTokens }
  }

  // MARK: - Initialization

  public init(codexPath: String = "~/.codex") {
    let expandedPath = NSString(string: codexPath).expandingTildeInPath
    self.sessionsDirectoryPath = "\(expandedPath)/sessions"

    // Check availability synchronously (fast), load data async
    isAvailable = FileManager.default.fileExists(atPath: sessionsDirectoryPath)
    loadStatsAsync()
    startWatching()
  }

  deinit {
    loadingTask?.cancel()
    stopWatching()
  }

  // MARK: - Public API

  /// Manually refresh stats
  public func refresh() {
    loadStatsAsync()
  }

  /// Cancel any in-progress loading operation
  public func cancelLoading() {
    loadingTask?.cancel()
    loadingTask = nil
    DispatchQueue.main.async { [weak self] in
      self?.isLoading = false
      self?.isLoadingInProgress = false
    }
  }

  // MARK: - Private Methods

  private func loadStatsAsync() {
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: sessionsDirectoryPath) else {
      DispatchQueue.main.async { [weak self] in
        self?.isAvailable = false
      }
      return
    }

    // Prevent concurrent loading - queue a reload instead
    if isLoadingInProgress {
      pendingReload = true
      return
    }

    // Cancel any existing task
    loadingTask?.cancel()

    isLoadingInProgress = true
    DispatchQueue.main.async { [weak self] in
      self?.isLoading = true
    }

    loadingTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }

      let jsonlFiles = self.findAllJSONLFiles()

      var aggregatedTokens = 0
      var aggregatedMessages = 0
      var aggregatedModelStats: [String: CodexModelUsage] = [:]

      for filePath in jsonlFiles {
        // Check for cancellation between files
        if Task.isCancelled { return }

        // Use lightweight parser optimized for global stats
        let parseResult = CodexSessionJSONLParser.parseForGlobalStats(at: filePath)

        let sessionTokens = parseResult.totalInputTokens + parseResult.totalOutputTokens
        aggregatedTokens += sessionTokens
        aggregatedMessages += parseResult.messageCount

        if let model = parseResult.model {
          var existing = aggregatedModelStats[model] ?? CodexModelUsage()
          existing.inputTokens += parseResult.totalInputTokens
          existing.outputTokens += parseResult.totalOutputTokens
          existing.cacheReadTokens += parseResult.cacheReadTokens
          existing.messageCount += parseResult.messageCount
          existing.sessionCount += 1
          aggregatedModelStats[model] = existing
        }
      }

      // Final cancellation check before updating UI
      if Task.isCancelled { return }

      let sessionCount = jsonlFiles.count

      await MainActor.run { [weak self] in
        guard let self else { return }
        self.totalTokens = aggregatedTokens
        self.totalSessions = sessionCount
        self.totalMessages = aggregatedMessages
        self.modelStats = aggregatedModelStats
        self.isAvailable = true
        self.lastUpdated = Date()
        self.isLoading = false
        self.isLoadingInProgress = false

        // If a reload was requested while we were loading, do it now
        if self.pendingReload {
          self.pendingReload = false
          self.loadStatsAsync()
        }
      }
    }
  }

  /// Recursively finds all .jsonl files in the sessions directory
  /// Codex stores sessions in nested date directories: ~/.codex/sessions/2026/01/02/
  private func findAllJSONLFiles() -> [String] {
    var jsonlFiles: [String] = []
    let fileManager = FileManager.default

    guard let enumerator = fileManager.enumerator(
      at: URL(fileURLWithPath: sessionsDirectoryPath),
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    for case let fileURL as URL in enumerator {
      if fileURL.pathExtension == "jsonl" {
        jsonlFiles.append(fileURL.path)
      }
    }

    return jsonlFiles
  }

  private func startWatching() {
    let fileManager = FileManager.default

    // Create directory if it doesn't exist
    if !fileManager.fileExists(atPath: sessionsDirectoryPath) {
      // Try again later when directory might exist
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
        self?.startWatching()
      }
      return
    }

    fileDescriptor = open(sessionsDirectoryPath, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      AppLogger.stats.error("Could not open Codex sessions directory for watching")
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .extend, .attrib, .link],
      queue: DispatchQueue.global(qos: .utility)
    )

    source.setEventHandler { [weak self] in
      guard let self else { return }
      // Debounce: cancel previous pending reload, schedule new one
      self.debounceWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.loadStatsAsync()
      }
      self.debounceWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    source.setCancelHandler { [weak self] in
      if let fd = self?.fileDescriptor, fd >= 0 {
        close(fd)
      }
    }

    source.resume()
    directoryWatcher = source
  }

  private func stopWatching() {
    directoryWatcher?.cancel()
    directoryWatcher = nil
  }

  // MARK: - Formatting Helpers

  private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000_000 {
      let billions = Double(count) / 1_000_000_000
      return String(format: "%.1fB", billions)
    } else if count >= 1_000_000 {
      let millions = Double(count) / 1_000_000
      return String(format: "%.1fM", millions)
    } else if count >= 1_000 {
      let thousands = Double(count) / 1_000
      return String(format: "%.1fK", thousands)
    }
    return "\(count)"
  }

  private func formatModelName(_ model: String) -> String {
    // Handle common Codex model name patterns
    if model.lowercased().contains("o3") {
      return "o3"
    } else if model.lowercased().contains("o4-mini") {
      return "o4-mini"
    } else if model.lowercased().contains("gpt-4") {
      return "GPT-4"
    } else if model.lowercased().contains("gpt-3") {
      return "GPT-3.5"
    }
    // Return short form if model name is too long
    if model.count > 20 {
      return String(model.prefix(17)) + "..."
    }
    return model
  }
}

// MARK: - CodexModelUsage

/// Usage statistics for a single Codex model
public struct CodexModelUsage: Sendable {
  public var inputTokens: Int = 0
  public var outputTokens: Int = 0
  public var cacheReadTokens: Int = 0
  public var cacheCreationTokens: Int = 0
  public var messageCount: Int = 0
  public var sessionCount: Int = 0

  public init() {}

  /// Total tokens for this model
  public var totalTokens: Int {
    inputTokens + outputTokens
  }
}
