//
//  AppLogger.swift
//  AgentHub
//
//  Centralized logging utility using os.Logger
//

import os

/// Centralized logging for AgentHub components
///
/// Usage:
/// ```swift
/// AppLogger.session.error("Failed to parse session: \(error)")
/// AppLogger.git.info("Found \(count) changed files")
/// AppLogger.watcher.warning("Stale watcher detected")
/// ```
enum AppLogger {
  private static let subsystem = "com.agenthub"

  /// Session-related logging (parsing, monitoring, lifecycle)
  static let session = Logger(subsystem: subsystem, category: "Session")

  /// Git operations (diff, worktree, commands)
  static let git = Logger(subsystem: subsystem, category: "Git")

  /// Intelligence/AI stream processing
  static let intelligence = Logger(subsystem: subsystem, category: "Intelligence")

  /// Orchestration and worktree execution
  static let orchestration = Logger(subsystem: subsystem, category: "Orchestration")

  /// Stats and metrics collection
  static let stats = Logger(subsystem: subsystem, category: "Stats")

  /// Search and indexing
  static let search = Logger(subsystem: subsystem, category: "Search")

  /// File watching and monitoring
  static let watcher = Logger(subsystem: subsystem, category: "Watcher")

  /// UI-related logging
  static let ui = Logger(subsystem: subsystem, category: "UI")
}
