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
public enum AppLogger {
  private static let subsystem = "com.agenthub"

  /// Session-related logging (parsing, monitoring, lifecycle)
  public static let session = Logger(subsystem: subsystem, category: "Session")

  /// Startup and persistence restoration logging
  public static let startup = Logger(subsystem: subsystem, category: "Startup")

  /// Git operations (diff, worktree, commands)
  public static let git = Logger(subsystem: subsystem, category: "Git")

  /// Intelligence/AI stream processing
  public static let intelligence = Logger(subsystem: subsystem, category: "Intelligence")

  /// Orchestration and worktree execution
  public static let orchestration = Logger(subsystem: subsystem, category: "Orchestration")

  /// Stats and metrics collection
  public static let stats = Logger(subsystem: subsystem, category: "Stats")

  /// Search and indexing
  public static let search = Logger(subsystem: subsystem, category: "Search")

  /// File watching and monitoring
  public static let watcher = Logger(subsystem: subsystem, category: "Watcher")

  /// UI-related logging
  public static let ui = Logger(subsystem: subsystem, category: "UI")

  /// Dev server lifecycle and output
  public static let devServer = Logger(subsystem: subsystem, category: "DevServer")

  /// iOS Simulator management
  public static let simulator = Logger(subsystem: subsystem, category: "Simulator")

  /// GitHub CLI operations (PRs, issues, reviews, checks)
  public static let github = Logger(subsystem: subsystem, category: "GitHub")
}
