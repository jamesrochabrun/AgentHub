//
//  CLIPathResolver.swift
//  AgentHub
//

import Foundation
import ClaudeCodeClient

enum CLIPathResolver {

  static func codexPaths(
    additionalPaths: [String],
    homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    uniquePaths(
      additionalPaths
        + ["\(homeDirectory)/.codex/local", "\(homeDirectory)/.codex/bin"]
        + ClaudeCodePathResolver.commonDeveloperPaths(homeDirectory: homeDirectory)
    )
  }

  static func executableSearchPaths(
    additionalPaths: [String] = [],
    homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    uniquePaths(
      additionalPaths
        + ["\(homeDirectory)/.claude/local", "\(homeDirectory)/.codex/local", "\(homeDirectory)/.codex/bin"]
        + ClaudeCodePathResolver.commonDeveloperPaths(homeDirectory: homeDirectory)
    )
  }

  private static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }
}
