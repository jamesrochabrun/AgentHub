//
//  GitHubLogger.swift
//  AgentHubGitHub
//
//  Logging for GitHub CLI operations
//

import os

enum GitHubLogger {
  /// GitHub CLI operations (PRs, issues, reviews, checks)
  static let github = Logger(subsystem: "com.agenthub", category: "GitHub")
}
